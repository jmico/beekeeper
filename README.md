# Beekeeper

Beekeeper is a framework for building applications with a microservices architecture.

![](./doc/images/beekeeper.svg)

A pool of worker processes handle requests and communicate with each other through a common message bus.

Clients send requests through a different message bus, which is isolated for security reasons.

Requests and responses are shoveled between the two buses by few router processes.


**Benefits of this architecture:**

- Scales horizontally very well. It is easy to add or remove workers or brokers.

- High availability. The system remains responsive even when several components fail.

- Easy integration of browsers via WebSockets or clients written in other languages.


**Key characteristics:**

- Broker is a messaging server like RabbitMQ or Apache ActiveMQ.

- Broker protocol is STOMP (see the [specification](https://stomp.github.io/stomp-specification-1.2.html)).

- RPC protocol is JSON-RPC 2.0 (see the [specification](https://www.jsonrpc.org/specification)).

- Message marshalling is JSON.

- No message persistence in the broker, it just pass on messages.

- No routing logic is defined in the broker, zero configuration is needed.

- Efficient multicast and unicast pushed notifications.

- Automatic load balancing.


**What does this framework provides:**

- `Beekeeper::Worker`, a base class for writing service workers with almost no additional code.

- `Beekeeper::Client`, a class for writing service clients.

- `bkpr` command which spawn and control worker processes.

- Automatic message routing between frontend and backend buses.

- Command line tools for monitoring and controlling remotely worker pools.

- Centralized logging, which can be shoveled to an external monitoring application.

- Performance metrics gathering, which can be shoveled to an external monitoring application.


## Getting Started

### Writing workers

Workers provide a service accepting certain RPC calls from clients.

The base class `Beekeeper::Worker` provides all the glue needed to accept requests and communicate trough the message bus with clients or another workers.

A worker class just declares on startup which methods it will accept, then implements them:

```
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
```

### Writing clients

Clients provide an API to interact with the remote service.

The class `Beekeeper::Client` provides methods to connect to the broker and make requests or send notifications. This is the API of the above service:

```
package MyApp::Client;

use Beekeeper::Client;

sub uppercase {
    my ($class, $str) = @_;

    my $client = Beekeeper::Client->instance;

    my $resp = $client->do_job(
        method => 'myapp.str.uc',
        params => { string => "hello!" },
    );

    return $resp->result;
}
```
Then other workers or clients can just:
```
use MyApp::Client;

print MyApp::Client->uppercase("hello!");
```

### Configuring

Beekeeper applications use two config files to define how clients, workers and brokers connect to each other. These files are searched for in ENV `BEEKEEPER_CONFIG_DIR`, `~/.config/beekeeper` and then `/etc/beekeeper`. File format is relaxed JSON, which allows comments and trailings commas.

The file `pool.config.json` defines all worker pools running on a host, specifying which logical bus should be used and which services it will run. For example:

```
[{
    "pool-id" : "myapp",
    "bus-id"  : "backend",
    "workers" : {
        "MyApp::Worker" : { "workers_count" : 4 },
    },
}]
```
The file `bus.config.json` defines all logical buses used by the application, specifying the conection parameters to the brokers that will service them. For example:

```
[{
    "bus-id"  : "backend",
    "host"    : "localhost",
    "user"    : "backend",
    "pass"    : "def456",
    "vhost"   : "/back",
}]
```
Neither the worker code nor the client code have hardcoded references to the logical message bus or the broker connection parameters, they communicate to each other using the definitions in these two files.


### Running

To start or stop a pool of workers you use the `bkpr` command. Given the above example config, this will start 4 processes running `MyApp::Worker` code:
```
bkpr --pool-id "myapp" start
```
When started it daemonize itself and fork all worker processes, then continue monitoring those forked processes and *immediately* respawn defunct ones.

The framework includes these command line tools to manage worker pools:

- `bkpr-top` allows to monitor in real time the performance of all workers.

- `bkpr-log` allows to monitor in real time the log output of all workers.

- `bkpr-restart` gracefully restart local or remote worker pools.


## Performance

Beekeeper is pretty lightweight, so the performance depends mostly of *the broker* performance. These are the numbers of a local setup running RabbitMQ:

- A `do_job` synchronous call to a remote method adds 1.5 ms of latency and involves 4 network round trips. This translates to a maximum of 650 synchronous calls per second.

- A `do_async_job` asynchronous call to a remote method takes 0.1 ms. This translates to a maximum of 10000 asynchronous calls per second (just the call, then it must wait for responses).

- Scheduling a remote task with `do_background_job` takes 0.1 ms. This translates to a maximum of 10000 calls per second.

- Sending a notification with `send_notification` takes 0.1 ms. A worker can emit 10000 notifications per second, even over 15000 if these are smaller than 1 KB.

- A worker processing remote calls adds 0.75 ms of latency and involves 2 network round trips. So a single worker can handle a maximum of 1300 requests per second.

- A worker adds an overhead of 0,04% CPU load per request.

- A worker uses 10 MB of resident memory.

- Frontend router adds 5 ms of latency and involves 2 additional network round trips.

**Hypothetical example:**

Suppose it is needed to handle 1000 requests per second to a task that take 25 ms to complete, uses 20 MB of memory and has 10% CPU load. Servers are in the same datacenter and the network roundtrip is 0.1 ms.

Adding framework and network latency, a single worker can handle:
```
1000 ms / (25 ms + 0.75 ms + 0.1 ms * 2) = 38.5 req/s
```
In order to handle 1000 requests per second:
```
1000 req/s / 38.5 req/s = 26 workers
```
The memory needed is:
```
26 workers * (20 MB + 10 MB) = 780 MB
```
The CPU needed is:
```
26 * 10% + 1000 * 0,04% = 300% = 3 cores
```
End user latency is:
```
25 ms + 0.75 ms + 5 ms + 0.1 ms * 6 = 32 ms + user latency
```
Backend broker receives 2000 msg/s and sends 2000 msg/s, giving a 4000 msg/s total traffic.
Frontend broker receives 1000 msg/s and sends 1000 msg/s, giving a 2000 msg/s total traffic.

These numbers will, of course, worsen if broker performance degrades under load.


## Examples

`examples/basic` is a barebones example of the usage of Beekeper.

`examples/flood` allows to estimate the performance of a Beekeper setup.

`examples/webstomp` use a service from a browser using WebSockets.

`examples/chat` implements a real world setup with isolated buses and redundancy.


## Dependencies

This framework requires `Anyevent`, `JSON::XS`, `Term::ReadKey`, `Test::Class`, and `ps`.

To install these dependencies on a Debian system do:
```
apt install libanyevent-perl
apt install libjson-xs-perl
apt install libterm-readkey-perl
apt install libtest-class-perl
apt install procps
```

## Licensing

Copyright 2015 José Micó.

This is free software; you can redistribute it and/or modify it under the same
terms as the Perl 5 programming language itself.
