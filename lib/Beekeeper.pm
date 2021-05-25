package Beekeeper;

use strict;
use warnings;

our $VERSION = '0.03';

1;

__END__

=pod

=encoding utf8

=head1 NAME
 
Beekeeper - Framework for building applications with a microservices architecture
 
=head1 VERSION
 
Version 0.03

=head1 SYNOPSIS

Create a service:

  package My::Service::Worker;
  
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

Use the service from a client:

  package main;
  use My::Service;
  
  My::Service->msg( "foo!" );
  
  My::Service->echo( foo => "bar" );


=head1 DESCRIPTION

Beekeeper is a framework for building applications with a microservices architecture.

=begin HTML

<p><img src="https://raw.githubusercontent.com/jmico/beekeeper/master/doc/images/beekeeper.svg"/></p>

=end HTML

A pool of worker processes handle requests and communicate with each other through a common 
message bus.

Clients send requests through a different set of message buses, which are isolated for security 
reasons.

Requests and responses are shoveled between buses by a few router processes.


B<Benefits of this architecture:>

- Scales horizontally very well. It is easy to add or remove workers, routers or brokers.

- High availability. The system remains responsive even when several components fail.

- Easy integration of browsers via WebSockets or clients written in other languages.


B<Key characteristics:>

- Broker is a MQTT messaging server, like Mosquitto or HiveMQ.

- Broker protocol is MQTT 5 (see the specification at L<https://docs.oasis-open.org/mqtt/mqtt/v5.0/mqtt-v5.0.html>).

- RPC protocol is JSON-RPC 2.0 (see the specification at L<https://www.jsonrpc.org/specification>).

- Message marshalling is JSON.

- No message persistence in the broker, it just passes on messages.

- No routing logic is defined in the broker.

- Blends synchronous and asynchronous workers or clients.

- Efficient multicast and unicast push notifications.

- Inherent load balancing.


B<What does this framework provides:>

- C<Beekeeper::Worker>, to create service workers.

- C<Beekeeper::Client>, to create service clients.

- C<bkpr> command which spawns and controls worker processes.

- Command line tools for monitoring and controlling worker pools.

- An internal broker suitable for development or running tests. 

- Automatic message routing between frontend and backend buses.

- Centralized logging, which can be shoveled to an external monitoring application.

- Performance metrics gathering, which can be shoveled to an external monitoring application.


=head1 Getting Started

=head3 Creating workers

Workers provide a service accepting certain RPC calls from clients. The base class C<Beekeeper::Worker> 
provides all the glue needed to accept requests and communicate trough the message bus with 
clients or another workers.

A worker class just declares on startup which methods it will accept, then implements them:

  package MyApp::Worker;
  
  use base 'Beekeeper::Worker';
  
  sub on_startup {
      my $self = shift;
  
      $self->accept_jobs(
          'myapp.str.uc' => 'uppercase',
      );
  }
  
  sub uppercase {
      my ($self, $params) = @_;
  
      return uc $params->{'string'};
  }


=head3 Creating clients

Clients of the service need an interface to use it without knowledge of the underlying RPC 
mechanisms. The class C<Beekeeper::Client> provides methods to connect to the broker and make 
RPC calls.

This is the interface of the above service:

  package MyApp::Client;
  
  use Beekeeper::Client;
  
  sub uppercase {
      my ($class, $str) = @_;
  
      my $client = Beekeeper::Client->instance;
  
      my $resp = $client->do_job(
          method => 'myapp.str.uc',
          params => { string => $str },
      );
  
      return $resp->result;
  }

Then other workers or clients can just:

  use MyApp::Client;
  
  print MyApp::Client->uppercase("hello!");


=head3 Configuring

Beekeeper applications use two config files to define how clients, workers and brokers connect 
to each other. These files are searched for in ENV C<BEEKEEPER_CONFIG_DIR>, C<~/.config/beekeeper> 
and then C</etc/beekeeper>. File format is relaxed JSON, which allows comments and trailings 
commas.

The file C<pool.config.json> defines all worker pools running on a host, specifying which logical 
bus should be used and which services it will run. For example:

  [{
      "pool-id" : "myapp",
      "bus-id"  : "backend",
      "workers" : {
          "MyApp::Worker" : { "workers_count" : 4 },
      },
  }]

The file C<bus.config.json> defines all logical buses used by the application, specifying the 
connection parameters to the brokers that will service them. For example:

  [{
      "bus-id"   : "backend",
      "host"     : "localhost",
      "username" : "backend",
      "password" : "def456",
  }]

Neither the worker code nor the client code have hardcoded references to the logical message 
bus or the broker connection parameters, they communicate to each other using the definitions 
in these two files.


=head3 Running

To start or stop a pool of workers you use the C<bkpr> command. Given the above example config, 
this will start 4 processes running C<MyApp::Worker> code:

  bkpr --pool-id "myapp" start

When started it daemonizes itself and forks all worker processes, then continues monitoring 
those forked processes and immediately respawns defunct ones.

The framework includes these command line tools to manage worker pools:

- C<bkpr-top> allows to monitor in real time the performance of all workers.

- C<bkpr-log> allows to monitor in real time the log output of all workers.

- C<bkpr-restart> gracefully restarts local or remote worker pools.


=head1 Performance

Beekeeper is pretty lightweight, so the performance depends mostly on *the broker* performance. 
These are 
ballpark performance measurements of a local setup running Mosquitto:

- A C<do_job> synchronous call to a remote method adds 1.5 ms of latency and involves 4 network 
round trips. This implies a maximum of 650 synchronous calls per second.

- A C<do_async_job> asynchronous call to a remote method takes 0.1 ms. This implies a maximum 
of 10000 asynchronous calls per second (just the call, then it must wait for responses).

- Scheduling a remote task with C<do_background_job> takes 0.1 ms. This implies a maximum of 
10000 calls per second.

- Sending a notification with C<send_notification> takes 0.1 ms. A worker can emit 10000 notifications 
per second, even over 15000 if these are smaller than 1 KB.

- A worker processing remote calls adds 0.3 ms of latency and involves 2 network round trips. 
So a single worker can handle a maximum of 3300 requests per second.

- A worker adds an overhead of 0,04% CPU load per request.

- A worker uses 10 MB of resident memory.

- Frontend router adds 5 ms of latency and involves 2 additional network round trips.

B<Hypothetical example:>

Suppose it is needed to handle 1000 requests per second to a task that takes 25 ms to complete, 
uses 20 MB of memory and has 2% CPU load. Servers are in the same datacenter and the network 
roundtrip is 0.1 ms.

Adding framework and network latency, a single worker can handle:

  1000 ms / (25 ms + 0.3 ms + 0.1 ms * 2) = 39 req/s

In order to handle 1000 requests per second:

  1000 req/s / 39 req/s = 26 workers

The memory needed is:

  26 workers * (20 MB + 10 MB) = 780 MB

The CPU needed is:

  26 * 2% + 1000 * 0,04% = 92% = 1 core

End user latency is:

  25 ms + 0.3 ms + 5 ms + 0.1 ms * 6 = 31 ms + user latency

Backend broker receives 2000 msg/s and sends 2000 msg/s, giving a 4000 msg/s total traffic.
Frontend broker receives 1000 msg/s and sends 1000 msg/s, giving a 2000 msg/s total traffic.

These numbers will improve a bit when running on beefier CPUs, and worsen a lot if broker performance 
degrades under heavy load.


=head1 Examples

This distribution includes some examples that can be run out of the box using an internal C<ToyBroker> 
(so no install of a proper broker is needed):

C<examples/basic> is a barebones example of the usage of Beekeper.

C<examples/flood> allows to estimate the performance of a Beekeper setup.

C<examples/webstomp> use a service from a browser using WebSockets.

C<examples/chat> implements a real world setup with isolated buses and redundancy.


=head1 SEE ALSO

L<Notes about supported MQTT brokers|https://github.com/jmico/beekeeper/blob/master/doc/Brokers.md> configuration.

L<Diagram of message routing|https://raw.githubusercontent.com/jmico/beekeeper/master/doc/images/routing.svg> between clients, workers and buses.

L<Beekeeper::WorkerPool>, L<Beekeeper::Client>, L<Beekeeper::Worker>.

=head1 SOURCE REPOSITORY
 
The source code repository for Beekeeper can be found at L<https://github.com/jmico/beekeeper>

=head1 AUTHOR

José Micó, C<jose.mico@gmail.com>

=head1 COPYRIGHT AND LICENSE

Copyright 2015-2021 José Micó.

This is free software; you can redistribute it and/or modify it under the same 
terms as the Perl 5 programming language itself.

This software is distributed in the hope that it will be useful, but it is 
provided “as is” and without any express or implied warranties. For details, 
see the full text of the license in the file LICENSE.

=cut
