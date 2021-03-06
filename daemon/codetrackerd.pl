#! /usr/bin/perl -w

use strict;
use POSIX;
use Linux::Inotify2;

my $DEBUG = 0;
my $CAN_RESPAWN = 1;

my $LOGDIR = "/var/log/codetracker";
my $LOGFILE = $LOGDIR."/codetrackerd.log";
my $OUTFILE = $LOGDIR."/codetrackerd.out";
my $ERRFILE = $LOGDIR."/codetrackerd.err";
my $PIDFILE = $LOGDIR."/codetrackerd.pid";

# Get the currently logged in user - must use this method to get the username since
# this script must be run as root, yet we do not want the name of the root user
my $USER = getlogin();

# Get the timestamp of the last time this source file was modified
my $SRC_TIMESTAMP = (stat($0))[9];

my $DIR_IGNORE_PATTERN = "\\.svn\\|library\\|\\.git";
my @IGNORE_SUFFIXES = ("\.swp", "\.swx", "~");
my @IGNORE_PREFIXES = ("\.");

## TODO: handle interrupt signals
## TODO: handle configs
## TODO: do bookeeping / reconcile watches with existing dirs

sub respawn;
sub logMsg($);
sub addWatch($);
sub handleNotifyEvent($);
sub handleFileModify($$);
sub handleDirCreate($$);
sub handleDirDelete($$);


# Gather command line arguments
my @input_dirs = ();
foreach my $arg (@ARGV) {
	if ($arg =~ /^-u(.+)/) {
		$USER = $1;
		next;
	}
	if (!-e $arg) {
		print "Directory $arg does not exist - ignoring...\n";
		next;
	}
	push(@input_dirs, $arg);
}
if ($#input_dirs < 0) {
	print "No valid directory paths specified! Exiting...\n";
	exit;
}

# A pid file will be created to ensure only one instance of this process is running.
# If a pid file exists and the pid it contains matches a currently running process,
# then exit. Otherwise, delete it.
if (-e $PIDFILE && !$DEBUG) {
	open(PID, "<$PIDFILE");
	my $pid = <PID>;
	chomp($pid);
	close PID;

	if ($pid) {
		# Check if the pid matches a currently running process
		if (kill(0, $pid)) {
			print "Process already running with PID $pid! Exiting...\n";
			exit;
		} else {
			unlink $PIDFILE;
		}
	}	
}

# Fork a child process, which will remain running as the daemon
logMsg('Code tracker daemon initializing - forking child process...');
my $fork_pid = fork;
if (!defined($fork_pid)) {
	logMsg("Process failed to fork: $!");
	die;
}

# The parent process should exit, after giving the forked process enough time to
# daemonize. The child process will have a pid of 0.
if ($fork_pid) {
	logMsg('Child forked successfully - parent exiting...');
	sleep(3);
	exit;
}

# Daemonize child process by creating a new session and setting it as the session leader
# http://pubs.opengroup.org/onlinepubs/009604499/functions/setsid.html
POSIX::setsid;

print "Code tracker daemon initializing...\n";

if (!$DEBUG) {
	# Create a new file with the current pid
	logMsg("Creating pid file $PIDFILE");
	if (open(PID, ">$PIDFILE")) {
		print PID "$$\n";
		close PID;
	} else {
		print "Cannot open PID file: $PIDFILE. Exiting...\n";
		exit;
	}
}

# Create an Inotify2 object to be notified of file system events
my $inotify = new Linux::Inotify2 or die "Unable to create new inotify object: $!" ;
$inotify->blocking(0);
my %watches = ();

# For each dir passed in on the command line, recursively get all subdirectories
# and add a watch to each one
foreach my $arg (@input_dirs) {
	my @dirsToWatch = `find $arg -type d | grep -v "$DIR_IGNORE_PATTERN"`;
	foreach my $dir (@dirsToWatch) {
		chomp($dir);
		addWatch($dir) unless $DEBUG;
	}
}

print "Code tracker daemon running (PID:$$,USER:$USER)\n";
logMsg("Code tracker daemon running (PID:$$,USER:$USER)");

# Redirect standard in to /dev/null, and standard out and standard error to log files
logMsg("Redirecting STDOUT and STDERR to $OUTFILE and $ERRFILE");
open(STDIN, "/dev/null");
open(STDOUT, ">>$OUTFILE") if !$DEBUG;
open(STDERR, ">>$ERRFILE") if !$DEBUG;

# Main daemon loop - poll for notify events at regular intervals
logMsg('Listening for file system events...');
while (!$DEBUG) {
	# Poll for events (non-blocking call)
	$inotify->poll;

	# Respawn this process if the source file is modified
        my $modified_time = (stat($0))[9];
	respawn if $modified_time != $SRC_TIMESTAMP;

	sleep(1);
}

print "Exiting...\n";
exit;

sub respawn {
	# If respawning is enabled, clean up by releasing all watches and deleting the
	# pid file, then re-execute this script with the original command line arguments
	if ($CAN_RESPAWN) {
		logMsg("Change detected in source file - cleaning up and respawning process...");
		foreach my $key (keys %watches) {
			$watches{$key}->cancel();
		}
		unlink $PIDFILE;
		exec($0, "-u".$USER, @input_dirs);
	}

	# If the exec() returns and this code is reached, then something went wrong,
	# so exit
	if ($CAN_RESPAWN) {
		logMsg("Respawn failed: $!\nExiting...");
		exit;
	}
}

sub logMsg($) {
	my $msg = shift;
	if ($msg) {
		my $time = `date +'[%F %T]'`;
		chomp($time);
		if (!-e $LOGDIR) {
			mkdir $LOGDIR or print "Cannot create log dir: $LOGDIR\n";
			return;
		}
		if (open(LOG, ">>$LOGFILE")) {
			print LOG "$time $msg\n";
			close LOG;
		} else {
			print "Cannot open log file: $LOGFILE\n";
		}
	}
}

sub addWatch($) {
	my $path = shift;
	if (!$watches{$path}) {
		$watches{$path} = $inotify->watch($path, IN_MODIFY|IN_CREATE|IN_DELETE_SELF, \&handleNotifyEvent);
		logMsg("Watch added for $path");
	}
}

sub handleNotifyEvent($) {
	my $event =  shift;
	my $path = $event->fullname;

	if (-d $path) {
		# Add a new watch for any newly created dirs
		handleDirCreate($path, $event) if $event->IN_CREATE;
	} elsif (-f $path) {
		# Notify tracker API of file modifications
		handleFileModify($path, $event) if $event->IN_MODIFY;
	} else {
		# Cancel the watch to release resources if a dir is deleted
		handleDirDelete($path, $event) if $event->IN_DELETE_SELF;
	}
}

sub handleFileModify($$) {
	my $filename = shift;

	# Get the file owner - only handle the modify event if the file is owned
	# by the current user or root
	my $owner = getpwuid((stat($filename))[4]);
	return unless $owner =~ /$USER|root/;
	
	my $timestamp = `date +%s`;
	chomp($timestamp);
	my $cmd = "curl 64.208.137.22:3000/save-event/$USER/$timestamp";
	logMsg("File $filename modified; file owner is $owner");
	logMsg("Running $cmd");
	my $response = `$cmd`;
}

sub handleDirCreate($$) {
	my $dirname = shift;
	addWatch($dirname);
}

sub handleDirDelete($$) {
	my $dirname = shift;
	my $event = shift;
	$event->w->cancel();
	delete $watches{$dirname};
	logMsg("Directory $dirname deleted; watch removed");
}

sub testNotify {
	my $e = shift;
	my $name = $e->fullname;
	print "$name accessed\n" if $e->IN_ACCESS;
	print "$name modified\n" if $e->IN_MODIFY;
	print "$name meta changed\n" if $e->IN_ATTRIB;
	print "$name fd closed\n" if $e->IN_CLOSE_WRITE;
	print "$name read-only fd closed\n" if $e->IN_CLOSE_NOWRITE;
	print "$name opened\n" if $e->IN_OPEN;
	print "$name moved from\n" if $e->IN_MOVED_FROM;
	print "$name moved to\n" if $e->IN_MOVED_TO;
	print "$name created\n" if $e->IN_CREATE;
	print "$name deleted\n" if $e->IN_DELETE;
	print "$name self deleted\n" if $e->IN_DELETE_SELF;
	print "$name moved\n" if $e->IN_MOVE_SELF;
}
