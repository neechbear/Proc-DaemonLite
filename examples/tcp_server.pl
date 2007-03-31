#!/usr/bin/perl -w

use 5.8.0;
use strict;
use warnings;
use lib qw(./lib ../lib);
use Proc::DaemonLite qw();
use IO::Socket;
use IO::Select;

my $socket = IO::Socket::INET->new(
		LocalHost => '127.0.0.1',
		LocalPort => '2048',
		Proto     => 'tcp',
		Listen    => 1,
		Reuse     => 1, 
	) || die "Could not create socket: $!";
my $select = IO::Select->new($socket);

my $daemon = Proc::DaemonLite->new(
		'syslog'  => "local7",
		'user'    => "apache",
		'group'   => "apache",
		'chroot'  => "/var/www",
	);
my $pid = $daemon->daemonise;
$daemon->log_info("Forked in to background PID $pid");
 
$SIG{__WARN__} = sub { $daemon->log_warn(@_); };
$SIG{__DIE__} = sub { $daemon->log_die(@_); };

while (1) {
	next unless $select->can_read;
	next unless my $client = $socket->accept;

	my $child = $daemon->spawn_child;
	if ($child == 0) {
		close($socket);
		while (local $_ = <$client>) {
			s/[\r\n]+//g;
			$daemon->log_warn("Client said: '$_'\n");
			print $client "You said: '$_'\n";
		}

	} else {
		$daemon->log_warn("Spawned child PID $child");
	}
}
 
$daemon->log_warn("Finished parent loop");
close($socket);
$daemon->kill_children;

exit;

__END__


