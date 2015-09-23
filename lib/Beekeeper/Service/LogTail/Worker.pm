package Beekeeper::Service::LogTail::Worker;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME

Beekeeper::Service::LogTail::Worker - Pool log browser

=head1 VERSION

Version 0.01

=head1 SYNOPSIS

=head1 DESCRIPTION

"/topic/log.backend.$level.$self->{service}",

=cut

use Beekeeper::Worker ':log';
use base 'Beekeeper::Worker';

use JSON::XS;

my @Log_buffer;


sub on_startup {
    my $self = shift;

    $self->{max_size} = $self->{config}->{max_size} || 1000;

    $self->{_BUS}->subscribe(
        destination    => "/topic/log.#",
        on_receive_msg => sub {
            my ($body_ref, $msg_headers) = @_;

            my $req = decode_json($$body_ref);

            $req->{params}->{type} = $req->{method};

            push @Log_buffer, $req->{params};

            shift @Log_buffer if (@Log_buffer > $self->{max_size});
        }
    );

    $self->accept_jobs(
        '_bkpr.logtail.tail' => 'tail',
    );
}

sub buffer_entry {
    my ($self, $params, $req) = @_;

    $params->{level} = $req->{method};

    push @Log_buffer, $params;

    shift @Log_buffer if (@Log_buffer > $self->{max_size});
}

sub tail {
    my ($self, $params) = @_;

# TODO:
#         count   => $opt_count,
#         level   => $opt_level,
#         host    => $opt_host, 
#         pool    => $opt_pool, 
#         class   => $opt_class,
#         message => $opt_message,
#         after   => $last,
 
    my $count = $params->{'count'} || 10;

    my $end = scalar @Log_buffer - 1;
    my $start = $end - $count + 1;
    $start = 0 if $start < 0;

    my @latest = @Log_buffer[$start..$end];

    if ($params->{after}) {
        @latest = grep { $_->{tstamp} > $params->{after} } @latest;
    }

    return \@latest;
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
