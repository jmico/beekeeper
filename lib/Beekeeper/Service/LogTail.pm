package Beekeeper::Service::LogTail;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME

Beekeeper::Service::LogTail - Pool log browser

=head1 VERSION

Version 0.01

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 METHODS

=item tail ( %filters )

=cut


use Beekeeper::Client;

sub tail {
    my ($class, %filters) = @_;

    my $client = Beekeeper::Client->instance;

    my $resp = $client->do_job(
        method => '_bkpr.logtail.tail',
        _auth_ => '0,BKPR_ADMIN',
        params => \%filters,
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
