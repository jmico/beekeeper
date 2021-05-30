package Beekeeper::Service::Router;

use strict;
use warnings;

our $VERSION = '0.03';

use Exporter 'import';

our @EXPORT_OK = qw(
    assign_remote_address
    remove_remote_address
    remove_caller_address
);

our %EXPORT_TAGS = ('all' => \@EXPORT_OK );


sub assign_remote_address {
    my ($self, $address) = @_;

    my $params = {
        address     => $address,
        caller_id   => $self->{_CLIENT}->{caller_id},
        caller_addr => $self->{_CLIENT}->{caller_addr},
        auth_data   => $self->{_CLIENT}->{auth_data},
    };

    my $guard = $self->__use_authorization_token('BKPR_ROUTER');

    $self->call_remote(
        method => '_bkpr.router.assign_addr',
        params => $params,
    );
}

sub remove_remote_address {
    my ($self, $address) = @_;

    my $guard = $self->__use_authorization_token('BKPR_ROUTER');

    $self->call_remote(
        method => '_bkpr.router.remove_addr',
        params => { address => $address },
    );
}

sub remove_caller_address {
    my $self = shift;

    my $params = { caller_id => $self->{_CLIENT}->{caller_id} };

    my $guard = $self->__use_authorization_token('BKPR_ROUTER');

    $self->call_remote(
        method => '_bkpr.router.remove_addr',
        params => $params,
    );
}

1;

__END__

=pod

=encoding utf8

=head1 NAME

Beekeeper::Service::Router - Route messages between buses

=head1 VERSION

Version 0.03

=head1 SYNOPSIS

  $self->assign_remote_address( "frontend-user-123" );
  
  $self->send_notification(
      method  => 'myapp.info',
      address => 'frontend-user-123',
      params  => 'hello',
  );
  
  $self->remove_remote_address( "frontend-user-123" );

=head1 DESCRIPTION

Router workers shovel requests messages between frontend and backend brokers.

In order to push unicasted notifications all routers share a table of client
connections and server side assigned arbitrary addresses.

=head1 METHODS

=head3 assign_remote_address ( $address )

Assign an arbitrary address to remote caller.

This address can be used later to push notifications to the client.

The same address can be assigned to multiple remote clients, all of them will
receive the notifications sent to it.

=head3 remove_remote_address ( $address )

Cancel an address assignment. Clients will no longer receive notifications
sent to this address anymore.

=head3 remove_caller_address

Cancel an address assignment just for remote caller. Other remote clients
may still receive notifications from this address.

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
