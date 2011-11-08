package Plack::Middleware::Scrutiny;

=head1 NAME

Plack::Middleware::Scrutiny - Scrutinize your app with a full debugger

=head1 SYNPOSIS

  builder {
    enable 'Scrutiny';
    $app;
  };

  # Now pass ?_scrutinize=1 to your app for an inline debugger

=head1 DESCRIPTION

THIS IS A PROOF OF CONCEPT, MUCH WORK REMAINS!

This middleware adds an in-band debugger to your web application. When triggered (via a query string), your C<< $app >> is executed in a forked context under the L<Devel::ebug> debugger. Instead of getting your application output, you get a web-based debugger UI so you can step through your program's execution.

=cut

use strict;
use warnings;
use parent qw(Plack::Middleware);
our $VERSION = '0.1';
use Socket;
use IO::Handle;
use Storable qw( freeze thaw );
use Data::Dumper;
# use Debug::Client;
use Devel::ebug;
use Plack::Request;
use Try::Tiny;
use File::ShareDir;
use Plack::App::File;
use Plack::Util::Accessor qw( files );

sub prepare_app {
  my $self = shift;
  my $root = try { File::ShareDir::dist_dir('Plack-Middleware-Scrutiny') }
    || 'share';
  $self->files(Plack::App::File->new(root => $root));
}

sub call {
  my($self, $env) = @_;
  print STDERR "parent: got ->call\n";
  if ($env->{PATH_INFO} =~ m!/scrutinize/!) {
    $env->{PATH_INFO} =~ s!.*/scrutinize/!/!;
    return $self->files->call($env);
  }
  my $q = Plack::Request->new($env);
  if(!$self->{in_debugger} && !$q->param('_scrutinize')) {
    print STDERR "parent: Calling original app\n";
    return $self->{app}->($env);
  }

  return sub {
    my $respond = shift;
    if($self->{in_debugger}) {
      print STDERR "parent: Already in debugger\n";
      return $self->in_debugger($env, $respond);
    } else {
      print STDERR "parent: Starting new debugger\n";
      $self->{in_debugger} = 1;
      return $self->new_request($env, $respond);
    }
  };
}

sub new_request {
  my ($self, $env, $respond) = @_;

  $self->start_child;

  # If the child says anything, we'll deal with it
  $self->{child_watcher} = AnyEvent->io(
    fh => $self->{from_child},
    poll => 'r',
    cb => sub {
      print STDERR "parent: waiting for response\n";
      my ($cmd, $val) = $self->receive('from_child');

      if($cmd eq 'response') {
        print STDERR "Response: " . Dumper($val);
        $self->{response} = $val;
        # We're done, kill watcher
        delete $self->{child_watcher};
        #return $val;

      } elsif( $cmd eq 'read' ) {
        my ($len, $offset) = @$val;
        my $buf;
        my $read_retval = $env->{'psgi.input'}->read($buf, $len, $offset);
        $self->send( to_child => read_result => [$buf, $read_retval], 1 );

      } elsif( $cmd eq 'seek' ) {
        my ($position, $whence) = @$val;
        my $buf;
        my $seek_retval = $env->{'psgi.input'}->seek($position, $whence);
        $self->send( to_child => read_result => [$seek_retval], 1);
      }
    }
  );
  
  print STDERR "parent: fixing env\n";
  my $env_trimmed = {%$env}; # shallow copy
  delete $env_trimmed->{'psgi.input'};
  delete $env_trimmed->{'psgix.io'};
  delete $env_trimmed->{'psgi.errors'};

  # Get the child running
  $self->send( to_child => request => $env_trimmed );

  print STDERR "parent: Creating debug client\n";
  # $self->{debug_client} = Debug::Client->new(
    # host => 'localhost',
    # port => 8080,
  # );
  use Devel::ebug;
  $self->{debug_client} = Devel::ebug->new;

  # Wait for client to connect
  sleep 1; # Give the client a second to get started
  print STDERR "parent: listening for debugger connect\n";
  $self->{debug_client}->attach(4011, 'bukifra');
  print STDERR "parent: got it!\n";

  return $self->in_debugger($env, $respond);
}

sub in_debugger {
  my ($self, $env, $respond) = @_;
  my $q = Plack::Request->new($env);

  # Child has completed? If so just give that back
  if($self->{response}) {
    print STDERR "parent: got response, sending to browser\n";
    $self->{in_debugger} = 0;
    $respond->($self->{response});
  }

  my $cmd = $q->param('cmd') || 'codeline';
  my $out;
  print STDERR "parent: sending $cmd to debugger\n";
  $out = $self->{debug_client}->$cmd;
  $out = $self->{debug_client}->codeline;
  # $out = join("\n", $self->{debug_client}->codelines(
  
  # Child has completed? If so just give that back
  if($self->{response}) {
    print STDERR "parent: got response, sending to browser\n";
    $self->{in_debugger} = 0;
    delete $self->{debug_client};
    $respond->($self->{response});
  }

  $respond->([
    200,
    ['Content-type' => 'text/html'],
    [qq|
      <html>
        <head>
          <link rel="stylesheet" type="text/css" href="/scrutinize/scrutinize.css" />
        </head>
        <body>
          <h1>Scrutiny!</h1>
          <a href="?cmd=step">Step In</a>
          <a href="?cmd=next">Step Over</a>
          <a href="?cmd=run">Run</a>
          <a href="?cmd=get_stack_trace">Stacktrace</a>
          <pre>$out</pre>
        </body>
      </html>
    |]
  ]);

}

sub send {
  my ($self, $dest, $type, $val) = @_;

  my $dest_handle = $self->{$dest};
 
  print STDERR "send $dest $type\n";
  print STDERR Dumper($val);
  print $dest_handle "$type\n";
  
  $val = freeze($val);
  $val = unpack('h*', $val);
  print $dest_handle "$val\n";
}

sub receive {
  my ($self, $source) = @_;

  print STDERR "receive $source\n";

  my $source_handle = $self->{$source};

  my $cmd = <$source_handle>;
  chomp $cmd;
  
  my $val = <$source_handle>;
  chomp $val;
  $val = pack('h*',$val);
  $val = thaw($val);

  return ($cmd, $val);
}

sub start_child {
  my ($self) = @_;
  my ($to_child,  $from_child);
  my ($to_parent, $from_parent);

  pipe($from_child,  $to_parent);
  pipe($from_parent, $to_child);

  $to_child->autoflush(1);
  $to_parent->autoflush(1);

  $self->{to_child}    = $to_child;
  $self->{to_parent}   = $to_parent;
  $self->{from_child}  = $from_child;
  $self->{from_parent} = $from_parent;

  my $pid = fork();
  if(!$pid) {
    # child
    $self->manage_child;
  } else {
    # parent
    print STDERR "parent: saving child pid $pid\n";
    $self->{child_pid} = $pid;
  }
}

sub manage_child {
  my ($self) = @_;
  my $to_parent = $self->{to_parent};
  my $from_parent = $self->{from_parent};
  my $input = Plack::Middleware::Scrutiny::IOWrap->new( manager => $self );
  while(1) {
    print STDERR "child: waiting for env\n";
    my ($cmd, $env) = $self->receive('from_parent');
    $env->{'psgi.input'} = $input;

    # give the parent a second or two to start listening
    print STDERR "child: Loading debugger\n";
    # $ENV{PERLDB_OPTS} = "RemotePort=localhost:8080";
    $ENV{SECRET} = 'bukifra';
    require Enbugger;
    print STDERR "child: Loading ebug\n";
    Enbugger->load_debugger('ebug');
    print STDERR "child: stopping...\n";
    Enbugger->stop;

    print STDERR "child: Running \$app\n";
    my $response = $self->{app}->($env);
    print STDERR "child: sending response\n";

    $self->send(to_parent => response => $response);
    exit;
  }
}

package Plack::Middleware::Scrutiny::IOWrap;

sub new {
  my $class = shift;
  my $self = {@_};
  return bless $self, $class;
}

sub read {
  my ($self, $buf, $len, $offset) = @_;
  $self->{manager}->send( to_parent => read => [$len, $offset] );
  my ($cmd, $val) = $self->{manager}->receive('from_parent');
    # require Enbugger;
    # Enbugger->stop;
  my ($bufval, $retval) = @$val;
  $_[1] = $bufval;
  return $retval;
}

sub seek {
  my ($self, $position, $whence) = @_;
  $self->{manager}->send( to_parent => seek => [$position, $whence] );
  my ($cmd, $val) = $self->{manager}->receive('from_parent');
    # require Enbugger;
    # Enbugger->stop;
  my ($retval) = @$val;
  return $retval;
}

1;

