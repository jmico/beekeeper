package Beekeeper::Service::Router;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME

Beekeeper::Service::Router - Route messages between buses

=head1 VERSION

Version 0.01

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 METHODS

=item bind

=item unbind

=cut


use Beekeeper::Client;

sub bind {
    my ($class, %args) = @_;

    my $client = Beekeeper::Client->instance;

    $client->do_background_job(
        method => '_bkpr.router.bind',
        params => {
            addr  => $args{address}, 
            queue => $args{req}->{_headers}->{'x-forward-reply'},
        },
    );
}

sub unbind {
    my ($class, %args) = @_;

    my $client = Beekeeper::Client->instance;

    $client->do_background_job(
        method => '_bkpr.router.unbind',
        params => {
            queue => $args{req}->{_headers}->{'x-forward-reply'},
        },
    );
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
