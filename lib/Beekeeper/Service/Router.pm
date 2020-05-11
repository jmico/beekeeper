package Beekeeper::Service::Router;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME

Beekeeper::Service::Router - Route messages between buses

=head1 VERSION

Version 0.01

=head1 SYNOPSIS

  $self->bind_session( $req, "frontend.user-123" );
  
  $self->send_notification(
      method => 'myapp.info@frontend.user-123',
      params => 'hello',
  );
  
  $self->unbind_session( $req, "frontend.user-123" );
  
  $self->unbind_address( "frontend.user-123" );

=head1 DESCRIPTION

Router workers shovel requests messages between frontend and backend brokers.

In order to push unicasted notifications all routers share a table of client
connections and server side assigned arbitrary addresses.

=head1 METHODS

=item bind_session ( $req, $address )

Assign an arbitrary address to a remote client connection.

This address can be used later to push notifications to the client.

The same address can be assigned to several connections at the same time.

=item unbind_session ( $req )

Cancel a connection bind.

=item unbind_address ( $address )

Cancel every connection bind to a given address.

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
