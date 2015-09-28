package MyApp::Service::Auth::Worker;

use strict;
use warnings;

use Beekeeper::Worker ':log';
use base 'Beekeeper::Worker';

use Beekeeper::Service::Router;


sub on_startup {
    my $self = shift;

    $self->accept_jobs(
        'myapp.auth.login' => 'login',
        'myapp.auth.logout' => 'logout',
    );
}

sub login {
    my ($self, $params, $req) = @_;

    my $user = $params->{username};

    # Create a virtual destination that will be routed to caller
    Beekeeper::Service::Router->bind( 
        address => "\@frontend.user-$user",
        req     => $req,
    );

    $self->send_notification(
        method => 'myapp.chat.message@frontend.' . "user-$user",
        params => { from => '', message => "Welcome!" },
    );
}

sub logout {
    my ($self, $params, $req) = @_;

    Beekeeper::Service::Router->unbind( 
        #address     => "\@frontend.user-$login",
        #destination => $req->sender_address,
        req => $req,
    );
}

1;
