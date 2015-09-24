package Tests::Supervisor;

use strict;
use warnings;

use base 'Tests::Service::Base';

use Test::More;
use Time::HiRes 'sleep';


sub start_test_workers : Test(startup) {
    my $self = shift;

    $self->start_workers('Tests::Service::Worker');
};

sub test_00_compile_client : Test(1) {
    my $self = shift;

    use_ok('Beekeeper::Service::Supervisor');
}


sub test_01_client : Test(9) {
    my $self = shift;

    my $svc = 'Beekeeper::Service::Supervisor';

    my $workers = $svc->get_workers_status;

    # $workers = [
    #
    # {
    #   'host'  => 'hostname',
    #   'jps'   => '0.00',
    #   'pool'  => 'test-pool',
    #   'pid'   => 4916,
    #   'load'  => '0.00',
    #   'nps'   => '0.00',
    #   'queue' => ['test'],
    #   'class' => 'Tests::Service::Worker'
    # }, ...

    is( scalar @$workers, 3 );

    my $sevices = $svc->get_services_status;
    ok( exists $workers->[0]->{'class'} );
    ok( exists $workers->[0]->{'queue'} );
    is( $workers->[0]->{'pool'}, 'test-pool' );

    # $sevices = {
    #
    # 'Tests::Service::Worker' => {
    #     'nps'   => '0.00',
    #     'load'  => '0.00',
    #     'jps'   => '0.00'
    #     'count' => 2,
    # }, ...

    is( scalar keys %$sevices, 2 );
    ok( exists $sevices->{'Tests::Service::Worker'} );
    ok( exists $sevices->{'Beekeeper::Service::Supervisor::Worker'} );

    is( $sevices->{'Tests::Service::Worker'}->{count}, 2 );
    is( $sevices->{'Beekeeper::Service::Supervisor::Worker'}->{count}, 1 );
}

1;
