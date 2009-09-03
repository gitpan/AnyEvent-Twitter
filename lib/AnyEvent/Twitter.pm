package AnyEvent::Twitter;
use common::sense;
use Carp qw/croak/;
use AnyEvent;
use AnyEvent::HTTP;
use URI::URL;
use JSON;
use MIME::Base64;
use Scalar::Util qw/weaken/;
use Encode;

use base qw/Object::Event/;

our $VERSION = '0.25';

our $DEBUG = 0;

=head1 NAME

AnyEvent::Twitter - Implementation of the Twitter API for AnyEvent

=head1 VERSION

Version 0.25

=head1 SYNOPSIS

   use AnyEvent::Twitter;

   my $twitty =
      AnyEvent::Twitter->new (
         username => 'elm3x',
         password => 'secret123'
      );

   $twitty->reg_cb (
      error => sub {
         my ($twitty, $error) = @_;

         warn "Error: $error\n";
      },
      statuses_friends => sub {
         my ($twitty, @statuses) = @_;

         for (@statuses) {
            my ($pp_status, $raw_status) = @$_;
            printf "new friend status: %s: %s\n",
                  $pp_status->{screen_name},
                  $pp_status->{text};
         }
      },
   );

   $twitty->receive_statuses_friends;

   $twitty->update_status ("I'm bathing in my hot tub!", sub {
      my ($twitty, $status, $js_status, $error) = @_;

      if (defined $error) {
         # ...
      } else {
         # ...
      }
   });

   $twitty->start; # important!

=head1 DESCRIPTION

This is a lightweight implementation of the Twitter API. It's currently
still very limited and only implements the most necessary parts of the API
(for inclusion in my chat client).

If you are missing something don't hesitate to bug me!

This module uses L<AnyEvent::HTTP> for communicating with twitter. It currently
doesn't use OAuth based authentication but HTTP Basic Authentication, as it is
still not deprecated at the time of this writing (July 2009). If it will ever
be deprecated I will take care to implement OAuth.

The L<AnyEvent::Twitter> class inherits the event callback interface from
L<Object::Event>.

=head1 WEIGHTS AND RATE LIMITING

As the Twitter API is heavily rate limited in that kind of way that
you only have a few GET requests per hour (~150), this module implements
rate limiting. It will dynamically adjust the poll intervals (if you didn't
set a fixed poll intervall) to not exceed the requests per hours.

The C<bandwidth> parameter to the C<new> method (see below) controls how much
of the available requests are used. This is useful if you want to run multiple
clients for one twitter account and not have them take away each others request
per hours.

The C<$weigth> parameters to the C<receive_...> methods is for prioritizing
the requests. It works as follows: Each time a request can be made
every C<receive_...> 'job' gets his weight added to an internal counter. The
'job' with the highest count will be executed.

With this simple weight system you can say which kind of information you are
most interested in. For example giving the statuses of your friends a
C<$weight> of 2 and the mentions of your nickname a C<$weight> of 1 will result
in polling the statuses of your friends two times more often.

=head2 LOCAL TIME

B<NOTE:> It's crucial that your system clock is correctly set. As twitter
only reports an absolute time at which the rate limiting is reseted we
have to calculate the next poll time based on your clock.

=head1 METHODS

=over 4

=item my $obj = AnyEvent::Twitter->new (%args)

Creates a new twitter client object. C<%args> can contain these
arguments (C<username> and C<password> are mandatory):

=over 4

=item username => $username

Your twitter username.

=item password => $password

Your twitter password.

=item state => $new_state_struct

Initializer for the value given to the C<state> method (see below).

=item bandwidth => $bandwidth_factor

C<$bandwidth_factor> is the amount of "bandwidth" that is consumed
by the regular polling. The default value is C<0.95>. Any value
between 0 and 1 is valid.

If you give a value of C<0.5> this L<AnyEvent::Twitter> instance will
only use up half of the available requests per hours for the polls.

=back

=cut

sub new {
   my $this  = shift;
   my $class = ref ($this) || $this;
   my $self  = $class->SUPER::new (
      bandwidth        => 0.95,
      @_,
      enable_methods => 1
   );

   if ($self->{bandwidth} == 0) {
      croak "zero 'bandwidth' is an invalid value!\n";
   }

   unless (defined $self->{username}) {
      croak "no 'username' given to AnyEvent::Twitter\n";
   }

   unless (defined $self->{password}) {
      croak "no 'password' given to AnyEvent::Twitter\n";
   }

   $self->{state} ||= {};

   $self->{base_url} = 'http://www.twitter.com'
      unless defined $self->{base_url};

   return $self
}

sub _schedule_next_tick {
   my ($self, $last_req_hdrs) = @_;

   unless (defined $last_req_hdrs) {
      $self->_tick;
      return;
   }

   my $next_tick = 0;
   my $remaining_requests = $last_req_hdrs->{'x-ratelimit-remaining'};
   my $remaining_time     = $last_req_hdrs->{'x-ratelimit-reset'} - time;

   if (defined $self->{interval}) {
      $next_tick = $self->{interval};

   } elsif ($last_req_hdrs->{Status} eq '400'
            && $last_req_hdrs->{'x-ratelimit-reset'} > 0) {
      # probably not neccesary this special case, but better be safe...
      $next_tick = $last_req_hdrs->{'x-ratelimit-remaining'} - time;

   } elsif ($last_req_hdrs->{'x-ratelimit-reset'} > 0 # some basic sanity checks
            && $last_req_hdrs->{'x-ratelimit-limit'} != 0) {

      warn "REMAINING TIME: $remaining_time, "
           . "remaing reqs: $remaining_requests\n"
         if $DEBUG;

      if ($remaining_requests <= 0) {
         $next_tick = $remaining_time;

      } else {
         $next_tick = $remaining_time
                      / ($remaining_requests * $self->{bandwidth});
      }
   }

   warn "NEXT TICK IN $next_tick seconds\n" if $DEBUG;

   weaken $self;
   $self->{_tick_timer} =
      AnyEvent->timer (after => $next_tick, cb => sub {
         delete $self->{_tick_timer};
         $self->_tick;
      });

   $self->next_request_in ($next_tick, $remaining_requests, $remaining_time);
}

sub _tick {
   my ($self) = @_;

   my $max_task;
   for (keys %{$self->{schedule}}) {
      my $task = $self->{schedule}->{$_};
      $task->{wait} += $task->{weight};

      warn "TASK: $_ => $task->{wait} | $task->{weight}\n" if $DEBUG;

      $max_task = $task
         if not (defined $max_task)
            || $max_task->{wait} <= $task->{wait};

      warn "MAXTASK: $max_task->{wait}\n" if $DEBUG;
   }

   return unless $max_task;

   weaken $self;
   $max_task->{request}->(sub { $self->_schedule_next_tick ($_[0]) });
   $max_task->{wait} = 0;
}

=item $obj->start

This method will start requesting the data you are interested in.
See also the C<receive_...> methods, about how to say what you are
interested in.

=cut

sub start {
   my ($self) = @_;

   $self->_tick;
}

sub _get_basic_auth {
   my ($self) = @_;

   'Authorization' =>
      "Basic " . encode_base64 (join ':', $self->{username}, $self->{password});
}

sub _unescape_madness {
   my ($str) = @_;
   $str =~ s/&gt;/>/g;
   $str =~ s/&lt;/</g;
   $str
}


sub _analze_statuses {
   my ($self, $category, $data) = @_;

   my $st = ($self->{state}->{statuses}->{$category} ||= {});
   my $js;

   eval {
       $js = decode_json ($data);
   };
   if ($@) {
      $self->error ("error while parsing statuses for $category: $@");
   }

   my @statuses = map {
      $st->{id} = $_->{id} if $_->{id} > $st->{id};
      my $pps = {};

      $pps->{text}        = _unescape_madness $_->{text};
      $pps->{screen_name} = _unescape_madness $_->{user}->{screen_name};

      [$pps, $_]
   } @{$js || []};

   $self->event ('statuses_' . $category, @statuses);
}

sub _fetch_status_update {
   my ($self, $statuses_cat, $next_cb) = @_;

   my $category =
      $statuses_cat =~ /^(.*?)_timeline$/
         ? $1
         : $statuses_cat;

   my $st = ($self->{state}->{statuses}->{$category} ||= {});

   my $url  = URI::URL->new ($self->{base_url});
   $url->path_segments ('statuses', $statuses_cat . ".json");

   if (defined $st->{id}) {
      $url->query_form (since_id => $st->{id});
   }

   $url->query_form (count => $st->{count})
      if defined $st->{count};

   my $hdrs = { $self->_get_basic_auth };

   weaken $self;
   $self->{http_get}->{$category} =
      http_get $url->as_string, headers => $hdrs, sub {
         my ($data, $hdr) = @_;

         delete $self->{http_get}->{$category};

         #d# warn "FOO: " . JSON->new->pretty->encode ($hdr) . "\n";

         if ($hdr->{Status} =~ /^2/) {
            $self->_analze_statuses ($category, $data);

         } else {
            $self->error ("error while fetching statuses for $category: "
                          . "$hdr->{Status} $hdr->{Reason}");
         }

         $next_cb->($hdr);
      };
}

=item $obj->receive_statuses_friends ($count, [$weight])

This will enable polling for the statuses of your friends.

C<$count> is the amount of backlog the requests will get (see Twitter API
for the maximum values). If it is undefined no count will be set for the
request.

About C<$weight> see the L<WEIGHTS AND RATE LIMITING> section.

Whenever a new status is received the C<statuses_friends> event is emitted
(see below).

The C<id> of the seen statuses are recorded in a data structure which
you may set or retrieve via the C<state> method. I recommend caching the
state data structure.

=cut

sub receive_statuses_friends {
   my ($self, $count, $weight) = @_;

   weaken $self;
   $self->{schedule}->{statuses_friends} = {
      wait    => 0,
      weight  => $weight || 1,
      count   => $count,
      request => sub { $self->_fetch_status_update ('friends_timeline', @_) },
   };
}

=item $obj->receive_statuses_mentions ($count, [$weight])

This will enable polling for the statuses that mention you.

C<$count> is the amount of backlog the requests will get (see Twitter API
for the maximum values). If it is undefined no count will be set for the
request.

About C<$weight> see the L<WEIGHTS AND RATE LIMITING> section.

Whenever a new status is received the C<statuses_mentions> event is emitted
(see below).

The C<id> of the seen statuses are recorded in a data structure which
you may set or retrieve via the C<state> method. I recommend caching the
state data structure.

=cut

sub receive_statuses_mentions {
   my ($self, $count, $weight) = @_;

   weaken $self;
   $self->{schedule}->{statuses_mentions} = {
      wait    => 0,
      weight  => $weight || 1,
      count   => $count,
      request => sub { $self->_fetch_status_update ('mentions', @_) },
   };
}

sub _encode_status {
   encode ('utf-8', $_[0])
}

=item $obj->check_status_length ($status)

This method checks whether the string in C<$status> does not
exceed the maximum length of a status update.

If the length is ok a true value is returned.
If not, a false value is returned.

=cut

sub check_status_length {
   my ($self, $status) = @_;

   my $status_e = _encode_status $status;

   length ($status_e) <= 140;
}

=item $obj->update_status ($status, $done_cb->($obj, $status, $js, $error))

This will post an update of your status to twitter. C<$status> should not be
longer than 140 octets, you can check this with the C<check_status_length>
method (see above).

When the request is done the C<$done_cb> callback will be called with the
C<$status> as second argument if the update was successful and a human readable
C<$error> string as fourth argument in case of an error.  C<$js> is the JSON
response received from the server.

When the HTTP POST was successful the C<status_updated> event will be emitted.

=cut

sub update_status {
   my ($self, $status, $done_cb) = @_;

   my $status_e = _encode_status $status;

   my $url = URI::URL->new ($self->{base_url});
   $url->path_segments ('statuses', "update.json");
   $url->query_form (status => $status_e);

   my $hdrs = { $self->_get_basic_auth };

   weaken $self;
   $self->{http_posts}->{status} =
      http_post $url->as_string, '', headers => $hdrs, sub {
         my ($data, $hdr) = @_;
         delete $self->{http_posts}->{status};

         if ($hdr->{Status} =~ /^2/) {
            my $js;
            eval {
               $js = decode_json ($data);
            };
            if ($@) {
               $done_cb->($self, undef, undef,
                  "error when receiving your status update "
                  . "and parsing it's JSON: $@");
               return;
            }

            $done_cb->($self, $status, $js);

         } else {
            $done_cb->($self, undef, undef,
                       "error while updating your status: "
                       . "$hdr->{Status} $hdr->{Reason}");
         }
      };
}


=item my $state_struct = $obj->state

=item $obj->state ($new_state_struct)

With these methods you can set the internal sequence state. Whenever
a special kind of data is retrieved from Twitter the most recent
sequence id of the entry is remembered in the hash C<$state_struct>.

You can use this method to store the state or restore it. This is useful
if you have an application that shouldn't forget which entries it already saw.

=cut

sub state { defined $_[1] ? $_[0]->{state} = $_[1] : $_[0]->{state} }

=back

=head1 EVENTS

=over 4

=item statuses_<statuspath> => @statuses

This event is emitted whenever a new status was seen for the C<statuspath>
which can be one of these:

   friends
   public    (currently unimplemented)
   user      (currently unimplemented)
   mentions

C<@statuses> contains the new status updates.
Each element of C<@statuses> is an array reference containing:

   $status, $raw_status

C<$status> is a hash reference containing some post processed information
about the status update in C<$raw_status>. Most notable is the unescaping
of the texts (see below about C<$raw_status>).

It contains these key/value pairs:

=over 4

=item text => $text

This is the text of the status update.

=item screen_name => $screen_name

This contains the screen name of the user who posted this status update.

=back

C<$raw_status> is the parsed JSON structure of the new status. About the
interesting fields please consult
L<http://apiwiki.twitter.com/Twitter-API-Documentation>.

Please note that '<' and '>' are encoded as HTML entities '&lt;' and '&gt;',
so you will have to decode them yourself.

=item next_request_in => $seconds, $remaining_request, $remaining_time

This event is emitted when the timer for the next request is started.
C<$seconds> are the seconds until the next request is made.

C<$remaining_request> are the requests you have available within the next
C<$remaining_time> seconds.

=cut

sub next_request_in { }

=item error => $error_string

Whenever an error happens this event is emitted. C<$error_string> contains
a human readable error message.

=cut

sub error { }

=back

=head1 AUTHOR

Robin Redeker, C<< <elmex@ta-sa.org> >>

=head1 ACKNOWLEDGEMENTS

  Nuno Nunes (nfmnunes @ CPAN)     - For initial patch for mentions.

=head1 SEE ALSO

L<Object::Event>

L<http://apiwiki.twitter.com/Twitter-API-Documentation>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-anyevent-twitter at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=AnyEvent-Twitter>.
I will be notified and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc AnyEvent::Twitter

You can also look for information at:

=over 4

=item * IRC: AnyEvent::Twitter IRC Channel

See the same channel as the L<AnyEvent::XMPP> module:

  IRC Network: http://freenode.net/
  Server     : chat.freenode.net
  Channel    : #ae_xmpp

  Feel free to join and ask questions!

=item * Homepage:

L<http://software.schmorp.de/pkg/AnyEvent-Twitter.html>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/AnyEvent-Twitter>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/AnyEvent-Twitter>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=AnyEvent-Twitter>

=item * Search CPAN

L<http://search.cpan.org/dist/AnyEvent-Twitter>

=back

=head1 COPYRIGHT & LICENSE

Copyright 2009 Robin Redeker, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1;
