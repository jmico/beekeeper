package Beekeeper;

our $VERSION = '0.01_01';

1;

__END__

=head1 NAME
 
Beekeeper - Framework for building applications with a microservices architecture
 
=head1 VERSION
 
Version 0.01

=head1 SYNOPSIS

Create a service:

  package My::Service;

  use base 'Beekeeper::Worker';
  
  sub on_startup {
      my $self = shift;
      
      $self->accept_jobs( 'my.service.echo' => 'echo' );
      
      $self->accept_notifications( 'my.service.msg' => 'msg' );
  }
  
  sub echo {
      my ($self, $params) = @_;
      return $params;
  }
  
  sub msg {
      my ($self, $params) = @_;
      warn $params->{msg};
  }

Create an API for the service:

  package My::Service;

  use Beekeeper::Client;
  
  sub msg {
      my ($class, $message) = @_;
      my $cli = Beekeeper::Client->instance;
      
      $cli->send_notification(
          method => "my.service.msg",
          params => { msg => $message },
      );
  }
  
  sub echo {
      my ($class, %args) = @_;
      my $cli = Beekeeper::Client->instance;
      
      my $result = $cli->do_job(
          method => "my.service.echo",
          params => { %args },
      );
  
      return $result;
  }

Using the service from a client:

  package main;
  use My::Service;
  
  My::Service->msg( "foo!" );
  
  My::Service->echo( foo => bar);

=head1 DESCRIPTION

Beekeeper is a framework for building applications with a microservices architecture.

=begin HTML

<p><img src="httpa://github.com/jmico/beekeeper/doc/images/beekeeper.svg"/></p>

=end HTML

=head1 WARNING
 
This is beta quality software still under development.

=head1 SEE ALSO
 
L<Beekeeper::WorkerPool>, L<Beekeeper::Client>, L<Beekeeper::Worker>.

=head1 SOURCE REPOSITORY
 
The source code repository for Beekeeper can be found at L<https://github.com/jmico/beekeeper>

=head1 BUGS

Please report them!

=head1 AUTHOR

José Micó, C<< <jose.mico@gmail.com> >>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2015 by José Micó.

This is free software; you can redistribute it and/or modify it under the same 
terms as the Perl 5 programming language itself.

This software is distributed in the hope that it will be useful, but it is 
provided “as is” and without any express or implied warranties. For details, 
see the full text of the license in the file LICENSE.

=cut
