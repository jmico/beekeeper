package MyApp::Service::Auth::Worker;

use strict;
use warnings;

use Beekeeper::Worker ':log';
use base 'Beekeeper::Worker';

use Beekeeper::Service::Router ':all';

use MyApp::Service::Chat;


sub authorize_request {
    my ($self, $req) = @_;

    if ($req->{method} eq 'myapp.auth.login') {
        return REQUEST_AUTHORIZED;
    }

    $req->has_auth_tokens('CHAT_USER');
}

sub on_startup {
    my $self = shift;

    $self->accept_jobs(
        'myapp.auth.login'  => 'login',
        'myapp.auth.logout' => 'logout',
        'myapp.auth.kick'   => 'kick',
    );
}

sub login {
    my ($self, $params) = @_;

    my $username = $params->{username} || die "No username";
    my $password = $params->{password};

    # For simplicity, this example avoids resolving username <--> uuid  
    # mapping, and username and password are not verified at all
    my $uuid = $username;

    $self->set_auth_credentials( 
        uuid   => $uuid,
        tokens => 'CHAT_USER',
    );

    # Assign an address to the user connection in order to push messages to him
    $self->bind_connection( "frontend.user-$uuid" );

    MyApp::Service::Chat->send_notice(
        to_uuid => $uuid,
        message => "Welcome $username",
    );

    return 1;
}

sub logout {
    my ($self, $params) = @_;

    my $uuid = $self->get_current_uuid;

    MyApp::Service::Chat->send_notice(
        to_uuid => $uuid,
        message => "Bye!",
    );

    $self->unbind_connection;

    return 1;
}

sub kick {
    my ($self, $params) = @_;

    # For simplicity, this example avoids resolving username <--> uuid 
    my $kick_uuid = $params->{'username'};

    MyApp::Service::Chat->send_notice(
        to_uuid => $kick_uuid,
        message => "You were kicked",
    );

    $self->unbind_address( "frontend.user-$kick_uuid" );

    return 1;
}

1;
