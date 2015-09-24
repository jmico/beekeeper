package Tests::Service::Worker;

use strict;
use warnings;

use Beekeeper::Worker ':log';
use base 'Beekeeper::Worker';

use Time::HiRes 'sleep';

=pod

=head1 Test worker

Simple worker used to test Beekeeper framework.

=cut

sub on_startup {
    my $self = shift;

    $self->accept_notifications(
        'test.signal' => 'signal',
        'test.fail'   => 'fail',
        'test.echo'   => 'echo',
        'test.*'      => 'catchall',
    );

    $self->accept_jobs(
        'test.signal' => 'signal',
        'test.fail'   => 'fail',
        'test.echo'   => 'echo',
        'test.*'      => 'catchall',
    );
}

sub catchall {
    my ($self, $params) = @_;
    $self->signal($params);
}

sub signal {
    my ($self, $params) = @_;

    my ($signal) = $params->{signal} =~ m/(\w+)/;  # untaint
    my ($pid)    = $params->{pid}    =~ m/(\d+)/;

    sleep(rand() / 100); # helps to avoid signal races

    kill( $signal, $pid );
}

sub fail {
    my ($self, $params) = @_;

    warn $params->{warn} if $params->{warn};

    die $params->{die} if $params->{die};
}

sub echo {
    my ($self, $params) = @_;

    return $params;
}

1;
