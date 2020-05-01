package MyApp::Service::Calculator;

use strict;
use warnings;

use Beekeeper::Worker;
use base 'Beekeeper::Worker';


sub on_startup {
    my $self = shift;

    $self->accept_jobs(
        'myapp.calculator.eval_expr' => 'eval_expr',
    );
}

sub authorize_request {
    my ($self, $req) = @_;

    return REQUEST_AUTHORIZED;
}

sub eval_expr {
    my ($self, $params) = @_;

    my $expr = $params->{"expr"};

    unless (defined $expr) {
        # Return explicit error response. It will be not logged
        return Beekeeper::JSONRPC::Error->invalid_params;
    }

    ($expr) = $expr =~ m/^([ \d \. \+\-\*\/ ]*)$/x;

    unless (defined $expr) {
        # Throw a handled exception. It will be not logged
        die Beekeeper::JSONRPC::Error->invalid_params( message => 'Syntax error');
    }

    my $result = eval $expr;

    if ($@) {
        # Throw an unhandled exception. It will be logged
        # The client will receive a generic error response
        die $@;
    }

    return $result;
}

1;
