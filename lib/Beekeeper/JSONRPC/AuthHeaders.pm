package Beekeeper::JSONRPC::AuthHeaders;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME
 
Beekeeper::JSONRPC::AuthHeaders - Access to request auth headers
 
=head1 VERSION
 
Version 0.01

=cut

use Exporter 'import';

our @EXPORT_OK = qw(
    session_id
    uuid
    auth_tokens
    has_auth_tokens
    _auth
);

our %EXPORT_TAGS = ('all' => \@EXPORT_OK );


sub session_id {
    $_[0]->{_headers} ? $_[0]->{_headers}->{'x-session'} : undef;
}

sub uuid {
    $_[0]->{_auth} ? $_[0]->{_auth}->{uuid} : $_[0]->_auth->{uuid};
}

sub auth_tokens {
    $_[0]->{_auth} ? $_[0]->{_auth}->{tokens} : $_[0]->_auth->{tokens};
}

sub _auth {
    my $auth = $_[0]->{_headers}->{'x-auth-tokens'};
    return {} unless $auth && $auth =~ m/^ ([\w-]+) (,\w+)* $/x;
    $_[0]->{_auth} = { uuid => $1, tokens => $2 };
}

sub has_auth_tokens {
    my ($self, @tokens) = @_;

    my $auth = $self->auth_tokens;

    return unless $auth;
    return unless @tokens;

    foreach my $token (@tokens) {
        return unless defined $token;
        return unless $auth =~ m/\b$token\b/;
    }

    return Beekeeper::Worker::REQUEST_AUTHORIZED();
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
