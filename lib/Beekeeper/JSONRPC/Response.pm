package Beekeeper::JSONRPC::Response;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME
 
Beekeeper::JSONRPC::Response - JSON-RPC response.
 
=head1 VERSION
 
Version 0.01

=head1 SYNOPSIS

=head1 DESCRIPTION

Representation of a JSON-RPC notification (see <http://www.jsonrpc.org/specification>).

When a RPC call is made the worker replies with a Beekeeper::JSONRPC::Response object
if the invoked method was executed successfully. On error, a Beekeeper::JSONRPC::Error
is returned instead.

=head1 ACCESSORS

=over 4

=item result

Arbitrary value or data structure returned by the invoked method.
Is undefined if the invoked method does not returns anything.

=item id

The id of the request it is responding to. It is used internally for response 
matching, but it isn't very useful as this is unique only per client connection.

=item success

Always returns true. Useful to determine if method was executed successfully
or not ($response->result cannot be trusted as it may be undefined).

=back

=cut

sub new {
    my $class = shift;

    bless {
        jsonrpc => '2.0',
        result  => undef,
        id      => undef,
        @_
    }, $class;
}

sub result  { $_[0]->{result} }
sub id      { $_[0]->{id}     }

sub success { 1 }

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
