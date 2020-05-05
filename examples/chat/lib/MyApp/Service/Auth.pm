package MyApp::Service::Auth;

use strict;
use warnings;

use Beekeeper::Client;


sub new {
    my $class = shift;
    bless {}, $class;
}

sub do_job {
    my $self = shift;

    Beekeeper::Client->instance->do_job(@_);
}


# This is the API of service MyApp::Service::Auth

sub login {
    my ($self, %args) = @_;

    $self->do_job(
        method => 'myapp.auth.login',
        params => {
            username => $args{'username'},
            password => $args{'password'},
        },
    );
}

sub logout {
    my ($self) = @_;

    $self->do_job(
        method => 'myapp.auth.logout',
    );
}

sub kick {
    my ($self, %args) = @_;

    $self->do_job(
        method => 'myapp.auth.kick',
        params => { 
            username => $args{'username'},
        },
    );
}

1;
