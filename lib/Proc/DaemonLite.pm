############################################################
#
#   $Id$
#   Proc::DaemonLite - Simple server daemonisation module
#
#   Copyright 2006,2007 Nicola Worthington
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#
############################################################

package Proc::DaemonLite;
# vim:ts=4:sw=4:tw=78

use strict;
use 5.6.0;
use Carp qw(croak cluck carp);
use POSIX qw(:signal_h setsid WNOHANG);
use File::Basename qw(basename);
use IO::File;
use Cwd qw(getcwd);
use Sys::Syslog qw(:DEFAULT setlogsock);

use constant PIDPATH  => -d '/var/run' && -w _ ? '/var/run'
						: -d '/var/tmp' && -w _ ? '/var/tmp'
						: '/tmp';
use constant FACILITY => 'local0';

use vars qw($VERSION $DEBUG %CHILDREN);
BEGIN {
	use Cwd qw();
	use constant CWD => Cwd::cwd();
	use constant ARGV0 => $0;
	use constant ARGVN => @ARGV;
}


$VERSION = '0.02' || sprintf('%d', q$Revision$ =~ /(\d+)/g);
$DEBUG = $ENV{DEBUG} ? 1 : 0;

# These are private
my $objstore = {};
my ($pid, $pidfile, $saved_dir);



#
# Public methods
#

sub new {
	my ($self,$stor,$opts) = _params(\@_,
			valid => [qw(chroot pidfile user group syslog)]
		);

	$stor->{syslog} = 'local0';
	while (my ($k,$v) = each %{$opts}) {
		$stor->{$k} = $v;
	}
	$stor->{pid} = undef;

	DUMP('$self', $self);
	DUMP('$stor', $stor);
	return $self;
}

sub pid {
	my ($self,$stor,$opts) = _params(\@_);
	return $stor->{pid};
}

sub daemonise { &init_server; }
sub daemonize { &init_server; }

sub init_server {
	my ($self,$stor,$opts) = _params(\@_,
			valid => [qw(chroot pidfile user group syslog)]
		);

	if (defined $stor->{pid}) {
		log_warn("Cannot daemonise again; already daemonised as PID $stor->{pid}!");
		return;
	}

	for (qw(chroot pidfile user group syslog)) {
		$stor->{$_} = $opts->{$_} if exists $opts->{$_};
	}
	$stor->{uid} = getpwnam($stor->{user}) if defined $stor->{user};
	$stor->{gid} = getgrnam($stor->{group}) if defined $stor->{group};
	$stor->{pidfile} ||= _getpidfilename();
	DUMP('$stor', $stor);

	$self->_init_log($stor->{syslog}) if defined $stor->{syslog};
	my $fh = _open_pid_file($stor->{pidfile});

	_chroot($stor->{'chroot'}) if defined $stor->{'chroot'};

	_become_daemon();
	print $fh $$;
	close $fh;

	_change_privileges($stor->{uid}, $stor->{gid})
		if defined $stor->{uid} && defined $stor->{gid};

	$stor->{pid} = $$;
	return $stor->{pid};
}

sub spawn_child { &launch_child; };
sub launch_child {
	my ($self,$stor,$opts) = _params(\@_,
			valid => [qw(callback chroot home)],
		);
	$opts->{'chroot'} ||= $opts->{home};

	my $signals  = POSIX::SigSet->new(SIGINT, SIGCHLD, SIGTERM, SIGHUP);
	sigprocmask(SIG_BLOCK, $signals);    # block inconvenient signals
	log_die("Can't fork: $!") unless defined(my $child = fork());

	if ($child) {
		$CHILDREN{$child} = $opts->{callback} || 1;
	} else {
		$SIG{HUP} = $SIG{INT} = $SIG{CHLD} = $SIG{TERM} = 'DEFAULT';
		_chroot($opts->{'chroot'});
	}
	sigprocmask(SIG_UNBLOCK, $signals);    # unblock signals

	return $child;
}

sub kill_children {
	my ($self,$stor,$opts) = _params(\@_);

	DUMP('%CHILDREN',\%CHILDREN);
	kill TERM => keys %CHILDREN;

	# wait until all the children die
	sleep while %CHILDREN;
}

sub do_relaunch {
	my ($self,$stor,$opts) = _params(\@_);

	$> = $<;    # regain privileges
	unlink($pidfile);

	chdir(CWD) || croak sprintf("Unable to chdir to '%s': %s",CWD,$!);
	exec(ARGV0,ARGVN) || 
		croak sprintf("Unable to exec '%s': %s",join("','",ARGV0,ARGVN),$!);
}

sub log_debug  { shift; TRACE('log_debug()');  syslog('debug',   _msg(@_)) }
sub log_notice { shift; TRACE('log_notice()'); syslog('notice',  _msg(@_)) }
sub log_warn   { shift; TRACE('log_warn()');   syslog('warning', _msg(@_)) }
sub log_info   { shift; TRACE('log_info()');   syslog('info',    _msg(@_)) }

sub log_die {
	TRACE('log_die()');
	Sys::Syslog::syslog('crit', _msg(@_)) unless $^S;
	croak @_;
}



#
# Private stuff
#

no warnings 'redefine';
sub UNIVERSAL::a_sub_not_likely_to_be_here { ref($_[0]) }
use warnings 'redefine';

sub _blessed ($) {
	local($@, $SIG{__DIE__}, $SIG{__WARN__});
	return length(ref($_[0]))
			? eval { $_[0]->a_sub_not_likely_to_be_here }
			: undef
}

sub _refaddr($) {
	my $pkg = ref($_[0]) or return undef;
	if (_blessed($_[0])) {
		bless $_[0], 'Scalar::Util::Fake';
	} else {
		$pkg = undef;
	}
	"$_[0]" =~ /0x(\w+)/;
	my $i = do { local $^W; hex $1 };
	bless $_[0], $pkg if defined $pkg;
	return $i;
}

sub _params {
	local $Carp::CarpLevel = 2;

	my $self = shift(@{$_[0]});
	if (!ref($self) && (caller(1))[3] =~ /::new$/) {
		TRACE("Creating new $self object ...");
		# ref(my $class = shift) && croak 'Class name required';
		$self = bless \(my $dummy), $self;
		$objstore->{_refaddr($self)} = {};
	}

	croak 'Not called as a method' if !ref($self) || !UNIVERSAL::isa($self,__PACKAGE__);

	my $stor = $objstore->{_refaddr($self)};
	return ($self,$stor,$_[0]) unless @_ > 1;

	my %param;
	for (my $i = 1; $i < @_; $i += 2) {
		if (grep($_ eq $_[$i],qw(required valid)) && ref($_[$i+1]) eq 'ARRAY') {
			$param{$_[$i]} = $_[$i+1];
		} else {
			local $Carp::CarpLevel = 1;
			confess(sprintf(
				"Illegal key '%s' or value ref type '%s' passed to _params()",
				$_[$i], ref($_[$i+1])
			));
		}
	}

	my $opts = {};
	croak 'Odd number of elements passed when even was expected' if @{$_[0]} % 2;
	for (my $i = 0; $i < @{$_[0]}; $i += 2) {
		$opts->{$_[0]->[$i]} = $_[0]->[$i+1] if defined $param{valid}
			? grep($_[0]->[$i] eq $_,(@{$param{valid}},@{$param{required}})) ||
				( carp("Illegal parameter '$_[0]->[$i]' passed"), 0 )
			: 1
	}

	for my $key (@{$param{required}}) {
		croak "Required parameter '$key' missing when expected"
			unless exists $opts->{$key};
	}

	return ($self,$stor,$opts);
}

sub _init_log {
	my $self = shift;

	Sys::Syslog::setlogsock('unix');
	my $basename = File::Basename::basename(ARGV0);
	openlog($basename, 'pid', FACILITY);
	$SIG{__WARN__} = sub { $self->log_warn(@_); };
	$SIG{__DIE__}  = sub { $self->log_die(@_); };
}

sub _become_daemon {
	TRACE('_become_daemon()');
	croak "Can't fork" unless defined(my $child = fork);
	exit(0) if $child;   # parent dies;
	POSIX::setsid();     # become session leader
	open(STDIN,  '</dev/null');
	open(STDOUT, '>/dev/null');
	open(STDERR, '>&STDOUT');
	chdir('/');          # change working directory
	umask(0);            # forget file mode creation mask
	$ENV{PATH} = '/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin';
	delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};
	$SIG{CHLD} = \&_reap_child;
}

sub _msg {
	TRACE('_msg()');
	my $msg = join('', @_) || "Something's wrong";
	my ($pack, $filename, $line) = caller(1);
	$msg .= " at $filename line $line\n" unless $msg =~ /\n$/;
	$msg;
}

sub _getpidfilename {
	TRACE('_getpidfilename()');
	my $basename = File::Basename::basename(ARGV0, '.pl');
	return PIDPATH . "/$basename.pid";
}

sub _open_pid_file {
	TRACE('_open_pid_file()');
	my ($file) = $_[0] =~ /([^`]+)/;

	if (-e $file) {    # oops.  pid file already exists
		my $fh = IO::File->new($file) || return;
		my $pid = <$fh>;
		croak "Invalid PID file" unless $pid =~ /^(\d+)$/;
		croak "Server already running with PID $1" if kill 0 => $1;
		cluck "Removing PID file for defunct server process $pid.\n";
		croak "Can't unlink PID file $file" unless -w $file && unlink $file;
	}

	return IO::File->new($file, O_WRONLY | O_CREAT | O_EXCL, 0644)
		or die "Can't create $file: $!\n";
}

sub _change_privileges {
	TRACE('_change_privileges()');
	my ($uid, $gid) = @_;
	$) = "$gid $gid";
	$( = $gid;
	$> = $uid;           # change the effective UID (but not the real UID)
}

sub _chroot {
	TRACE('_chroot()');
	my ($dir) = $_ =~ /([^`]+)/;
	if ($dir) {
		local ($>, $<) = ($<, $>);         # become root again (briefly)
		chdir($dir)  || croak "chdir(): $!";
		chroot($dir) || croak "chroot(): $!";
		chdir('/')   || croak "chdir(): $!";
	}
	$< = $>;                               # set real UID to effective UID
}

sub _reap_child {
	TRACE('_reap_child()');
	while ((my $child = waitpid(-1, WNOHANG)) > 0) {
		$CHILDREN{$child}->($child) if ref $CHILDREN{$child} eq 'CODE';
		delete $CHILDREN{$child};
	}
}



#
# Speshul stuff
#

sub DESTROY {
	my $self = shift;
	delete $objstore->{_refaddr($self)};
}

END {
	$> = $<;    # regain privileges
	unlink $pidfile if defined $pid and $$ == $pid;
}

sub TRACE {
	return unless $DEBUG;
	carp(shift());
}

sub DUMP {
	return unless $DEBUG;
	eval {
		require Data::Dumper;
		my $msg = shift().': '.Data::Dumper::Dumper(shift());
		carp($msg);
	}
}

1;

=pod

=head1 NAME

Proc::DaemonLite - Simple server daemonisation module

=head1 SYNOPSIS

 use strict;
 use Proc::DaemonLite qw();
 
 my $daemon = Proc::DaemonLite->new(
                     syslog => "local7",
                     user => "joeb",
                     group => "staff",
                     chroot => "/home/jail",
                     pidfile => "/var/run/my.pid",
                 );
 my $pid = $daemon->daemonise;
 log_warn("Forked in to background PID $pid");
 
 $SIG{__WARN__} = \&log_warn;
 $SIG{__DIE__} = \&log_die;
 
 for my $cid (1..4) {
     my $child = $daemon->spawn_child;
     if ($child == 0) {
         log_warn("I am child PID $$") while sleep 2;
         exit;
     } else {
         log_warn("Spawned child number $cid, PID $child");
     }
 }
 
 sleep 20;
 $daemon->kill_children;

=head1 DESCRIPTION

Proc::DaemonLite is a basic server daemonisation module that trys
to cater for most basic Perl daemon requirements.

=head1 METHODS

=head2 new()

 my $daemon = new Proc::DaemonLite;

=head2 init_server()

 my $pid = init_server($pidfile, $user, $group);

=head2 daemonise()

Alias for init_server().

=head2 daemonize()

Alias for init_server().

=head2 pid()

 my $pid = $daemon->pid;

=head2 launch_child()

 my $child_pid = launch_child($callback, $home);

=head2 spawn_child()

Alias for launch_child().

=head2 kill_children()

 kill_children();

Terminate all children with a I<TERM> signal.

=head2 do_relaunch()

 do_relaunch()

Attempt to start a new incovation of the current script.

=head2 log_debug()

 log_debug(@messages);

=head2 log_info()

 log_info(@messages);

=head2 log_notice()

 log_notice(@messages);

=head2 log_warn()

 log_warn(@messages);

=head2 log_die()

 log_die(@messages);

=head2 %CHILDREN

I<%CHILDREN> is a hash of all child processes keyed by PID. Children
with registered callbacks will contain a reference to their callback
in this hash.

=head1 SEE ALSO

L<Proc::Deamon>, L<Proc::Fork>, L<Proc::Application::Daemon>,
L<Proc::Forking>, L<Proc::Background>, L<Net::Daemon>,
L<POE::Component::Daemon>, L<http://www.modperl.com/perl_networking/>,
L<perlfork>

=head1 VERSION

$Id$

=head1 AUTHOR

Nicola Worthington <nicolaw@cpan.org>

L<http://perlgirl.org.uk>

If you like this software, why not show your appreciation by sending the
author something nice from her
L<Amazon wishlist|http://www.amazon.co.uk/gp/registry/1VZXC59ESWYK0?sort=priority>? 
( http://www.amazon.co.uk/gp/registry/1VZXC59ESWYK0?sort=priority )

Original code written by Lincoln D. Stein, featured in "Network Programming
with Perl". L<http://www.modperl.com/perl_networking/>

Released with permission of Lincoln D. Stein.

=head1 COPYRIGHT

Copyright 2006,2007 Nicola Worthington.

This software is licensed under The Apache Software License, Version 2.0.

L<http://www.apache.org/licenses/LICENSE-2.0>

=cut


__END__



