package Beekeeper::JSONRPC::Error;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME
 
Beekeeper::JSONRPC::Error - JSON-RPC error.
 
=head1 VERSION
 
Version 0.01

=head1 SYNOPSIS

=head1 DESCRIPTION

Representation of a JSON-RPC error (see <http://www.jsonrpc.org/specification>).

When a RPC call could not be executed successfully the worker replies with a 
Beekeeper::JSONRPC::Error object. These objects may be returned also due to  
client side errors, like timeouts caused by network failure.

=head1 ACCESSORS

=over 4

=item error

A string providing a short description of the error.

=item error_code

A number that indicates the error type that occurred.

=item error_data

Arbitrary value or data structure containing additional information about the error.
This may be present or not.

=item id

The id of the request it is responding to. It is used internally for response 
matching, but it isn't very useful as this is unique only per client connection.

=item success

Always returns false. Useful to determine if method was executed successfully
or not ($response->result cannot be trusted as it may be undefined).

=back

=cut

use overload '""' => sub { $_[0]->{error}->{message} };

sub new {
    my ($class, %args) = @_;

    bless {
        jsonrpc => '2.0',
        id      => undef,
        error   => {
            code    => $args{code}    || -32603,
            message => $args{message} || "Internal error",
            data    => $args{data},
        },
    }, $class;
}

sub id      { $_[0]->{id}               }
sub message { $_[0]->{error}->{message} }
sub code    { $_[0]->{error}->{code}    }
sub data    { $_[0]->{error}->{data}    }

sub success { 0 }


=head1 Predefined errors

Error codes from and including -32768 to -32000 are reserved for predefined
errors of the JSON-RPC spec.

=cut

sub parse_error {
    shift->new(
        code    => -32700,
        message => "Parse error",
        data    => "Invalid JSON was received by the server",
        @_ 
    );
}

sub invalid_request {
    shift->new(
        code    => -32600,
        message => "Invalid request",
        data    => "The JSON sent is not a valid request object.",
        @_ 
    );
}

sub request_timeout {
    shift->new(
        code    => -31600,
        message => "Request timeout",
        @_ 
    );
}

sub method_not_found {
    shift->new(
        code    => -32601,
        message => "Method not found",
        data    => "The method does not exist",
        @_ 
    );
}

sub method_not_available {
    shift->new(
        code    => -31601,
        message => "Method not available",
        data    => "The method is not available.",
        @_ 
    );
}

sub invalid_params {
    shift->new(
        code    => -32602,
        message => "Invalid params",
        data    => "Invalid method parameters.",
        @_ 
    );
}

sub internal_error {
    shift->new(
        code    => -32603,
        message => "Internal error",
        data    => "Internal JSON-RPC error.",
        @_ 
    );
}

sub server_error {
    shift->new(
        code    => -32000,
        message => "Server error",
        @_ 
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
