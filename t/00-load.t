#!perl -T

use Test::More tests => 1;

BEGIN {
	use_ok( 'AnyEvent::Twitter' );
}

diag( "Testing AnyEvent::Twitter $AnyEvent::Twitter::VERSION, Perl $], $^X" );
