use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'AnyEvent::Twitter',
    AUTHOR              => 'Robin Redeker <elmex@x-paste.de>',
    LICENSE             => 'perl',
    VERSION_FROM        => 'lib/AnyEvent/Twitter.pm',
    ABSTRACT_FROM       => 'lib/AnyEvent/Twitter.pm',
    PL_FILES            => {},
    PREREQ_PM => {
        'Test::More'     => 0,
        'AnyEvent'       => 3.5,
        'AnyEvent::HTTP' => 0,
        'URI::URL'       => 0,
        'Object::Event'  => 0,
        'JSON'           => 0,
        'MIME::Base64'   => 0,
        'Scalar::Util'   => 0,
        'Encode'         => 0
    },
    dist                => {
       COMPRESS => 'gzip -9f',
       SUFFIX   => 'gz',
       PREOP => 'pod2text lib/AnyEvent/Twitter.pm | tee README >$(DISTVNAME)/README; chmod -R u=rwX,go=rX . ;',
    },
    clean               => { FILES => 'AnyEvent-Twitter' },
);
