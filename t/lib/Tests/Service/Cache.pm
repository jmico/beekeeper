package Tests::Service::Cache;

use strict;
use warnings;

use Beekeeper::Worker ':log';
use base 'Beekeeper::Worker';

use Beekeeper::Worker::Util 'shared_cache';

=pod

=head1 Test worker

Simple worker used to test shared cache.

=cut

sub on_startup {
    my $self = shift;

    $self->{Cache} = $self->shared_cache( id => "test", max_age => 10 );

    $self->accept_jobs(
        'cache.set'  => 'set',
        'cache.get'  => 'get',
        'cache.del'  => 'del',
        'cache.raw'  => 'raw_data',
        'cache.bal'  => 'balance',
    );
}

sub authorize_request {
    my ($self, $req) = @_;

    return REQUEST_AUTHORIZED;
}

sub get {
    my ($self, $params) = @_;

    $self->{Cache}->get( $params->{'key'} );
}

sub set {
    my ($self, $params) = @_;

    $self->{Cache}->set( $params->{'key'} => $params->{'val'} );
}

sub del {
    my ($self, $params) = @_;

    $self->{Cache}->delete( $params->{'key'} );
    1;
}

sub raw_data {
    my ($self, $params) = @_;

    $self->{Cache}->raw_data;
}

sub balance {
    my ($self, $params) = @_;

    my $pid = $$;
    my $runs = $self->{Cache}->get( $pid ) || 0;

    $self->{Cache}->set( $pid => $runs + 1 );
}

1;
