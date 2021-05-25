package Beekeeper::Service::Supervisor;

use strict;
use warnings;

our $VERSION = '0.03';

use Beekeeper::Client;


sub restart_pool {
    my ($class, %args) = @_;

    my $client = Beekeeper::Client->instance;

    $client->send_notification(
        method => '_bkpr.supervisor.restart_pool',
        __auth => 'BKPR_ADMIN',
        params => {
            host  => $args{'host'},
            pool  => $args{'pool'},
            delay => $args{'delay'},
        },
    );
}

sub restart_workers {
    my ($class, %args) = @_;

    my $client = Beekeeper::Client->instance;

    $client->send_notification(
        method => '_bkpr.supervisor.restart_workers',
        __auth => 'BKPR_ADMIN',
        params => {
            host  => $args{'host'},
            pool  => $args{'pool'},
            class => $args{'class'},
            delay => $args{'delay'},
        },
    );
}

sub get_workers_status {
    my ($class, %args) = @_;

    my $client = Beekeeper::Client->instance;

    my $resp = $client->do_job(
        method => '_bkpr.supervisor.get_workers_status',
        __auth => 'BKPR_ADMIN',
        params => {
            host  => $args{'host'},
            pool  => $args{'pool'},
            class => $args{'class'},
        },
    );

    return $resp->result;
}

sub get_services_status {
    my ($class, %args) = @_;

    my $client = Beekeeper::Client->instance;

    my $resp = $client->do_job(
        method => '_bkpr.supervisor.get_services_status',
        __auth => 'BKPR_ADMIN',
        params => {
            host  => $args{'host'},
            pool  => $args{'pool'},
            class => $args{'class'},
        },
    );

    return $resp->result;
}

1;

__END__

=pod

=encoding utf8

=head1 NAME

Beekeeper::Service::Supervisor - Worker pool supervisor.

=head1 VERSION

Version 0.03

=head1 SYNOPSIS

=head1 DESCRIPTION

Supervisor service keeps a table of the status and performance metrics of every 
worker connected to a logical bus in every broker.

This status table can be queried to shovel worker status to an external monitoring
application. The command line tool L<bkpr-top> display this status table.

=head1 SEE ALSO
 
L<bkpr-top>, L<bkpr-restart>.

=head1 AUTHOR

José Micó, C<jose.mico@gmail.com>

=head1 COPYRIGHT AND LICENSE

Copyright 2015-2021 José Micó.

This is free software; you can redistribute it and/or modify it under the same 
terms as the Perl 5 programming language itself.

This software is distributed in the hope that it will be useful, but it is 
provided “as is” and without any express or implied warranties. For details, 
see the full text of the license in the file LICENSE.

=cut
