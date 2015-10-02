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

use Exporter 'import';

our @EXPORT_OK = qw(
    bind_session
    unbind_session
    unbind_address
);

our %EXPORT_TAGS = ('all' => \@EXPORT_OK );


sub bind_session {
    my ($self, $request, $address) = @_;

    my $reply_queue = $request ? $request->{_headers}->{'x-forward-reply'} : undef;

    $self->do_job(
        method => '_bkpr.router.bind',
        _auth_ => '0,BKPR_ROUTER',
        params => {
            address     => $address, 
            reply_queue => $reply_queue,
            session_id  => $self->{_CLIENT}->{session_id},
            auth_tokens => $self->{_CLIENT}->{auth_tokens},
        },
    );
}

sub unbind_session {
    my $self = shift;

    $self->do_job(
        method => '_bkpr.router.unbind',
        _auth_ => '0,BKPR_ROUTER',
        params => {
            session_id => $self->{_CLIENT}->{session_id},
        },
    );
}

sub unbind_address {
    my ($self, $address) = @_;

    $self->do_job(
        method => '_bkpr.router.unbind',
        _auth_ => '0,BKPR_ROUTER',
        params => {
            address => $address, 
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
