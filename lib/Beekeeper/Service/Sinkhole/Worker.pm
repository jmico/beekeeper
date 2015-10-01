package Beekeeper::Service::Sinkhole::Worker;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME
 
Beekeeper::Service::Sinkhole::Worker - Default logger used by Beekeeper::Worker processes.
 
=head1 VERSION
 
Version 0.01

=head1 SYNOPSIS

=head1 DESCRIPTION

=cut

use Beekeeper::Worker ':log';
use base 'Beekeeper::Worker';

use Beekeeper::JSONRPC::Error;
use JSON::XS;


sub authorize_request {
    my ($self, $req) = @_;

    $req->has_auth_tokens('BKPR_SYSTEM');
}

sub on_startup {
    my $self = shift;

    $self->{Draining} = {};

    $self->accept_notifications(
        '_bkpr.sinkhole.unserviced_queues' => 'on_unserviced_queues',
    );

    my $local_bus = $self->{_BUS}->{bus_id};

    $self->{_BUS}->subscribe(
        destination    => "/topic/msg.$local_bus._sync.shared-workers-status.set",
        on_receive_msg => sub {
            my ($body_ref, $msg_headers) = @_;
            $self->on_worker_status( decode_json($$body_ref)->[1] );
        }
    );

}

sub log_handler {
    my $self = shift;

    # Use pool's logfile
    $self->SUPER::log_handler( foreground => 1 );
}


sub on_unserviced_queues {
    my ($self, $params) = @_;

    my $queues = $params->{queues};
 
    foreach my $queue (@$queues) {

        # Nothing to do if already draining $queue
        next if $self->{Draining}->{$queue};

        $self->{Draining}->{$queue} = 1;

        my $local_bus = $self->{_BUS}->{bus_id};
        log_error "Draining unserviced /queue/req.$local_bus.$queue";

        $self->accept_jobs( "$queue.*" => 'reject_job' );
    }
}

sub on_worker_status {
    my ($self, $status) = @_;

    return unless ($status->{queue});

    return if ($status->{class} eq 'Beekeeper::Service::Sinkhole::Worker');

    foreach my $queue (@{$status->{queue}}) {

        # Nothing to do if not draining queue
        next unless $self->{Draining}->{$queue};

        #
        delete $self->{Draining}->{$queue};

        my $local_bus = $self->{_BUS}->{bus_id};
        log_warn "Stopped draining /queue/req.$local_bus.$queue";

        $self->stop_accepting_jobs( "$queue.*" );
    }
}

sub reject_job {
    my ($self, $params, $job) = @_;

    # warn "Rejected job $job->{method}\n";

    # Just return a JSONRPC error response
    Beekeeper::JSONRPC::Error->method_not_available;
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
