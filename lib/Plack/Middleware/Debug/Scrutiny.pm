package Plack::Middleware::Debug::Scrutiny;

# Connect with: socat READL-LISTEN:8080,reuseaddr

use strict;
use warnings;
use parent qw(Plack::Middleware);
our $VERSION = '0.1';
use Socket;
use IO::Handle;
use Storable qw( freeze thaw );
use Data::Dumper;

sub prepare_app {
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

sub call {
  my($self, $env) = @_;
  my $to_child = $self->{to_child};
  my $from_child = $self->{from_child};

  print STDERR "parent: got ->call\n";
  print STDERR "parent: freezing env\n";
  my $env2 = {%$env}; # shallow copy

  delete $env2->{'psgi.input'};
  delete $env2->{'psgix.io'};
  delete $env2->{'psgi.errors'};

  $self->send( to_child => request => $env2 );

  while(1) {
    print STDERR "parent: waiting for response\n";
    my ($cmd, $val) = $self->receive('from_child');

    if($cmd eq 'response') {
      print STDERR "Response: " . Dumper($val);
      return $val;

    } elsif( $cmd eq 'read' ) {
      my ($len, $offset) = @$val;
      my $buf;
      my $read_retval = $env->{'psgi.input'}->read($buf, $len, $offset);
      $self->send( to_child => read_result => [$buf, $read_retval] );

    } elsif( $cmd eq 'seek' ) {
      my ($position, $whence) = @$val;
      my $buf;
      my $seek_retval = $env->{'psgi.input'}->seek($position, $whence);
      $self->send( to_child => read_result => [$seek_retval]);
    }
  }

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

sub manage_child {
  my ($self) = @_;
  my $to_parent = $self->{to_parent};
  my $from_parent = $self->{from_parent};
  my $input = Plack::Middleware::Debug::Scrutiny::IOWrap->new( manager => $self );
  while(1) {
    print STDERR "child: waiting for env\n";
    my ($cmd, $env) = $self->receive('from_parent');
    $env->{'psgi.input'} = $input;

    print STDERR "child: Loading debugger\n";
    $ENV{PERLDB_OPTS} = "RemotePort=localhost:8080";
    require Enbugger;
    Enbugger->stop;

    print STDERR "child: Running \$app\n";
    my $response = $self->{app}->($env);
    print STDERR "child: sending response\n";

    $self->send(to_parent => response => $response);
  }
}

package Plack::Middleware::Debug::Scrutiny::IOWrap;

sub new {
  my $class = shift;
  my $self = {@_};
  return bless $self, $class;
}

sub read {
  my ($self, $buf, $len, $offset) = @_;
  $self->{manager}->send( to_parent => read => [$len, $offset] );
  my ($cmd, $val) = $self->{manager}->receive('from_parent');
  my ($bufval, $retval) = @$val;
  $_[1] = $bufval;
  return $retval;
}

sub seek {
  my ($self, $position, $whence) = @_;
  $self->{manager}->send( to_parent => seek => [$position, $whence] );
  my ($cmd, $val) = $self->{manager}->receive('from_parent');
  my ($retval) = @$val;
  return $retval;
}

1;

