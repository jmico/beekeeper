package Beekeeper::Service::LogTail;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME

Beekeeper::Service::LogTail - Buffer log entries

=head1 VERSION

Version 0.01

=head1 SYNOPSIS

  my $l = Beekeeper::Service::LogTail->tail(
      count   => 100,
      level   => LOG_DEBUG,
      host    => '.*', 
      pool    => '.*', 
      service => 'myapp-foo',
      message => 'Use of uninitialized value',
      after   =>  now() - 10,
  );

=head1 DESCRIPTION

By default all workers use a C<Beekeeper::Logger> logger which logs errors and
warnings both to files and to a topic C</topic/log> on the message bus.

This service keeps an in memory buffer of every log entry sent to that topic in 
every broker in a logical message bus.

The command line tool C<bkpr-log> use this service to inspect logs in real time. 

This can be used to shovel logs to an external log management system.

=head1 METHODS

=item tail ( %filters )

Returns all buffered entries that match the filter criteria.

The following parameters are accepted:

C<count>: Number of entries to return, default is last 10.

C<level>: Minimal severity level of entries to return. 

C<host>: Regex that applies to worker host.

C<pool>: Regex that applies to worker pool.

C<service>: Regex that applies to service name.

C<message>: Regex that applies to error messages.

C<after>: Return only entries generated after given timestamp.

=cut


use Beekeeper::Client;

sub tail {
    my ($class, %filters) = @_;

    my $client = Beekeeper::Client->instance;

    my $resp = $client->do_job(
        method => '_bkpr.logtail.tail',
        _auth_ => '0,BKPR_ADMIN',
        params => \%filters,
    );

    return $resp->result;
}

1;

=head1 SEE ALSO
 
L<bkpr-log>.

=head1 AUTHOR

José Micó, C<jose.mico@gmail.com>

=head1 COPYRIGHT AND LICENSE

Copyright 2015 José Micó.

This is free software; you can redistribute it and/or modify it under the same 
terms as the Perl 5 programming language itself.

This software is distributed in the hope that it will be useful, but it is 
provided “as is” and without any express or implied warranties. For details, 
see the full text of the license in the file LICENSE.

=cut
