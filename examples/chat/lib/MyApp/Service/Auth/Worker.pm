package MyApp::Service::Auth::Worker;

use strict;
use warnings;

use Beekeeper::Worker ':log';
use base 'Beekeeper::Worker';

use Beekeeper::Service::Router;


sub authorize_request {
    my ($self, $req) = @_;

    if ($req->{method} eq 'myapp.auth.login') {
        return REQUEST_AUTHORIZED;
    }

    $req->has_auth_tokens('USER');
}

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
    my $pass = $params->{password};

    # In this example user credentials are not verified at all, 
    # but it should be done here in any real application
    my $uuid = $user;

    $self->set_credentials( 
        uuid   => $uuid, 
        tokens => [ "USER" ],
    );

    # Create a virtual destination that will be routed to caller
    Beekeeper::Service::Router->bind( 
        address => "\@frontend.user-$uuid",
        request => $req,
    );

    $self->send_notification(
        method => "myapp.chat.message\@frontend.user-$uuid",
        params => { from => '', message => "Welcome!" },
    );
}

sub logout {
    my ($self, $params, $req) = @_;

    Beekeeper::Service::Router->unbind( 
        #address     => "\@frontend.user-$login",
        #destination => $req->sender_address,
        request => $req,
    );
}

1;
