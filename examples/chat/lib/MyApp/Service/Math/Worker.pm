package MyApp::Service::Math::Worker;

use strict;
use warnings;

use Beekeeper::Worker ':log';
use base 'Beekeeper::Worker';


sub authorize_request {
    my ($self, $req) = @_;

    return REQUEST_AUTHORIZED;
}

sub on_startup {
    my $self = shift;

    $self->accept_jobs(
        'myapp.math.calculate' => 'calculate',
    );
}

sub calculate {
    my ($self, $params) = @_;

    my $expr = $params->{"expr"};
 
    return unless defined $expr;

    ($expr) = $expr =~ m/^([\s \d \. \+\-\*\%\^\/\(\) ]+)$/x;

    die "Invalid expression" unless (defined $expr);

    my $result = eval $expr;
    
    die $@ if $@;

    return $result;
}

1;
