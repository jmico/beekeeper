package MyApp::Service::Auth::Worker;

use strict;
use warnings;

use Beekeeper::Worker ':log';
use base 'Beekeeper::Worker';

use Beekeeper::Service::Router ':all';


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
        'myapp.auth.login'  => 'login',
        'myapp.auth.logout' => 'logout',
        'myapp.auth.kick'   => 'kick',
    );
}

sub login {
    my ($self, $params, $req) = @_;

    my $user = $params->{username};
    my $pass = $params->{password};

    # In this example user credentials are not verified at all
    my $uuid = $user;

    $self->set_credentials( 
        uuid   => $uuid,
        tokens => [ "USER" ],
    );

    # ...
    $self->bind_session( $req, "\@frontend.user-$uuid" );

    $self->send_notification(
        method => "myapp.chat.message\@frontend.user-$uuid",
        params => { message => "Welcome!" },
    );

    return 1;
}

sub logout {
    my ($self, $params, $req) = @_;

    my $uuid = $req->uuid;

    $self->send_notification(
        method => "myapp.chat.message\@frontend.user-$uuid",
        params => { message => "Bye!" },
    );

    $self->unbind_session;

    return 1;
}

sub kick {
    my ($self, $params) = @_;

    my $user = $params->{username};
    my $uuid = $user;

    $self->send_notification(
        method => "myapp.chat.message\@frontend.user-$uuid",
        params => { message => "You were kicked" },
    );

    $self->unbind_address( "\@frontend.user-$uuid" );

    return 1;
}

1;
