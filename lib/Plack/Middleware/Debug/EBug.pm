package Plack::Middleware::Debug::EBug;

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
  my ($to_child, $from_child);
  my ($to_parent, $from_parent);

  pipe($from_child, $to_parent);
  pipe($from_parent, $to_child);

  $to_child->autoflush(1);
  $to_parent->autoflush(1);
  # $from_child->autoflush(1);
  # $from_parent->autoflush(1);

  $self->{to_child}  = $to_child;
  $self->{to_parent} = $to_parent;
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

  print STDERR Dumper($env);
  my $env_store = freeze($env2);
  $env_store = unpack("h*",$env_store);
  print STDERR "parent: sending [$env_store]\n";
  print $to_child $env_store;
  print $to_child "\n";

  print STDERR "parent: waiting for response\n";
  my $response_frozen = <$from_child>;
  chomp $response_frozen;

  print STDERR "parent: response: [$response_frozen]\n";
  $response_frozen = pack('h*', $response_frozen);
  print STDERR "parent: thawing response\n";
  my $response = thaw($response_frozen);
  print STDERR "Response: " . Dumper($response);
  # $response = [200, ['Content-type' => 'text/html'],['<body>hello</body>']];

  return $response;

}


sub manage_child {
  my ($self) = @_;
  my $to_parent = $self->{to_parent};
  my $from_parent = $self->{from_parent};
  while(1) {
    print STDERR "child: waiting for env\n";
    my $env_freeze = <$from_parent>;
    chomp $env_freeze;
    print STDERR "child: got env [$env_freeze]\n";
    $env_freeze = pack('h*',$env_freeze);
    print STDERR "child: thawing env\n";
    my $env = thaw($env_freeze);
    print STDERR "child: Running \$app\n";
    my $response = $self->{app}->($env);
    print STDERR "child: sending response\n";
    my $response_frozen = freeze($response);
    $response_frozen = unpack('h*', $response_frozen);
    print STDERR "child: sending [$response_frozen]\n";
    print $to_parent $response_frozen;
    print $to_parent "\n";
  }
}

1;

