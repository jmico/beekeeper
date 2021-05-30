package MyApp::Calculator;

use strict;
use warnings;

use Beekeeper::Client;


sub new {
    my $class = shift;

    my $self = {};

    #TODO: Read frontend connection parameters from config file

    # Connect to bus 'frontend', wich will forward requests to 'backend'
    $self->{client} = Beekeeper::Client->instance(
        bus_id     => 'frontend', 
        forward_to => 'backend',
        host       => "localhost",
        port       =>  8001,
        username   => "frontend",
        password   => "abc123",
    );

    bless $self, $class;
}

sub client {
    my $self = shift;

    return $self->{client};
}

sub eval_expr {
    my ($self, $str) = @_;

    my $resp = $self->client->do_job(
        method => 'myapp.calculator.eval_expr',
        params => { expr => $str },
    );

    return $resp->result;
}

1;
