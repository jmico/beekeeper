package Beekeeper::Service::Supervisor;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME

Beekeeper::Service::Supervisor - Worker pool supervisor.

=head1 VERSION

Version 0.01

=head1 SYNOPSIS

=head1 DESCRIPTION

=cut

use Beekeeper::Client;


sub restart_pool {
    my ($class, %args) = @_;

    my $client = Beekeeper::Client->instance;

    $client->send_notification(
        method => '_bkpr.supervisor.restart_pool',
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
        params => {
            host  => $args{'host'},
            pool  => $args{'pool'},
            class => $args{'class'},
        },
        #TODO: raise_error => $args{'raise_error'} ?
    );

    return $resp->result;
}

sub get_services_status {
    my ($class, %args) = @_;

    my $client = Beekeeper::Client->instance;

    my $resp = $client->do_job(
        method => '_bkpr.supervisor.get_services_status',
        params => {
            host  => $args{'host'},
            pool  => $args{'pool'},
            class => $args{'class'},
        },
        #TODO: raise_error => $args{'raise_error'} ?
    );

    return $resp->result;
}

1;

=head1 AUTHOR

José Micó, C<< <jose.mico@gmail.com> >>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2015 by José Micó.

This is free software; you can redistribute it and/or modify it under the same 
terms as the Perl 5 programming language itself.

This software is distributed in the hope that it will be useful, but it is 
provided “as is” and without any express or implied warranties. For details, 
see the full text of the license in the file LICENSE.

=cut
