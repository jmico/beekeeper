package Beekeeper::JSONRPC::Request;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME
 
Beekeeper::JSONRPC::Notification - JSON-RPC request.
 
=head1 VERSION
 
Version 0.01

=head1 SYNOPSIS

=head1 DESCRIPTION

Representation of a JSON-RPC request (see <http://www.jsonrpc.org/specification>).

=head1 ACCESSORS

=over 4

=item method

A string with the name of the method to be invoked.

=item params

An arbitrary data structure to be passed as parameters to the defined method.

=item id

A value of any type, which is used to match the response with the request that it is replying to.

=back

=cut

use Beekeeper::JSONRPC::AuthHeaders ':all';

sub new {
    my $class = shift;
    bless {
        jsonrpc => '2.0',
        method  => undef,
        params  => undef,
        id      => undef,
        @_
    }, $class;
}

sub method     { $_[0]->{method} }
sub params     { $_[0]->{params} }
sub id         { $_[0]->{id}     }

sub response {
    $_[0]->{_response};
}

sub result {
    # Shortcut for $job->response->result
    return ($_[0]->{_response}) ? $_[0]->{_response}->{result} : undef;
}

sub success {
    # Shortcut for $job->response->success
    return ($_[0]->{_response}) ? $_[0]->{_response}->success : undef;
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
