#!/usr/bin/perl
# perlf.pl - perl for crash
#
# Copyright (C) 2013, Vinayak Menon <vinayakm.list@gmail.com>
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# What is extscriptutility for ?
#	At times we need to execute a series of crash
# commands to arrive at a result. i.e. we execute a command,
# get the output, pick an element from it, use it with the
# next command and so on. There are cases were this may take
# several steps. So this utility is to automate these steps.
# Another use is to execute a series of predefined crash commands
# to generate a bug report kind of thing.
#
# Now a brief on the components in this package.
# (1) A crash utility extension called 'extscript'.
#     This provides a crash command of same name.
# (2) A script. perlfc.pl is an example.
# (2) A protocol definition, for communication
#     between 'extscript' and the external script.
#
# The external script is run as a server by crash utility, when you
# invoke the extscript command. Why external script is the server ?
# Because it serves the crash utility by additonal commands. The
# script is not executed as is. We invoke the script from crash
# command line. In other words, we talk to the script from within
# the crash utility command line.
#
# An example.
#
# crash> extscript -f perl -a perl -a ./perlfc.pl
# crash> extscript -b bugreport
#
# The first command sets up the environement. This is
# similar to how we pass arguments to execlp. The last
# argument is the script. This command has to be modified
# depoending on the kind of script that we are running.
#
# The second command is the bypass command which actually
# executes the command we have encoded in the script.
# In this case "bugreport" is a command that is defined in
# perlfc.pl. The extecript bypasses this command to the
# script. The output in this case will be a bug_report.txt.
# And in other cases the output will be directly printed to
# crash console. Thus in simple words we are extending crash
# with additoinal commands encoded in a script.
#
# This perl script is an example of how to use the
# extscript extension of crash utility. Using the
# extscript extension, crash utility can connect to
# an external server. The server can send the commands
# to be executed, over a socket, to crash utility and
# get the output back. The ouput can be manipulated inside
# the script, and using a series of commands we can
# generate useful outputs that takes time when done manually
# through crash command line.
#
# A generic use case can be something of this sort.
# (1) Write a funtion in this or any script which obeys the protocol.
# (2) The funtion sends a "crash utility command" to crash utility.
# (3) The crash utility client (extscript) receives it and executes it.
# (4) The output is written to ./command.out.
# (5) This script parses the output and takes out what it needs.
# (6) From what it has derived from (5), sends the next command to crash
#     utility. This goes on.
#
# How to add a new command ?:
# Add the following to the "bypass_commands" table.
# (1) command tag to be set as argument to perlfc,
# (2) help
# (3) the corresponding funtion address.
# Done.
#
# All scripts must implement a help command.
# All scripts must implement a SIGINT signal handler. In the handler
# necessary cleanup has to be performed and exit.
#
# Protocol between crash and perlfc:
# The socket should match that of crash utility ("extscriptfcsocket").
#
# Note:
#	p->c : perl to crash
#	c->p : crash to perl
#
# (1) Every command send by crash must be
#     acked by perl (including an ACK from crash).
# (2) crash will not send an ACK for an ACK.
# (3) If a crash utility command has to be send to crash
#     for execution, it has to be in the following format.
#     ACKs not specified.
#
#     p->c: "EXECUTECOMMAND"
#     p->c: command split
#     p->c: "ENDOFCOMMAND"
#     c->p: "COMMANDEXECUTED"
#
# EXAMPLE: "kmem -i"
#
#     p->c: "EXECUTECOMMAND"
#     p->c: "kmem"
#     p->c: "-i"
#     p->c: "ENDOFCOMMAND"
#     c->p: "COMMANDEXECUTED"
#
# Currently the output of crash is received via ./command.out
# and not through the socket.
#
# VMLINUXPATH command can be send to crash to get the
# path to vmlinux.
#
# (4) A command should be a single string without any space
#     or special characters.
#
# (5) crash sends the BYPASS command followed by a string
#     containing the command to process and args.
#     perl should send DONE command after procesing is
#     completed.
#
# (6) perl should wait for SHUTDOWN command from crash
#     before exiting.

use IO::Socket::UNIX;
use File::Compare;

my $VERSION = "1.0";

# The command list for generating
# bug report.
my @commands = (
	# Command table format:
	# "command", "command utility function", "skip flag, set this to skip
	# command output being included in bug report".
	# If skip is set, only errors encountered while executing the command
	# will be included in the bug report.

	["set radix 16", \&f_hex, 0, 0],
	["rd -a linux_banner", \&f_generic, 0, "BUILD INFO"],
	["sys", \&f_generic, 0, "SYSTEM INFO"],
	["mach", \&f_generic, 0, "MACHINE INFO"],
	["bt -asT", \&f_generic, 0, "CURRENT TASK BACKTRACES FOR ALL CPUS"],
	["dev", \&f_generic, 0, "CHAR AND BLOCK DEVICE DATA"],
	["dev -i", \&f_generic, 0, "I/O PORT USAGE"],
	["dev -d", \&f_generic, 0, "DISK IO STATISTICS"],
	["files", \&f_generic, 0, "OPEN FILES IN THE CURRENT CONTEXT"],
	["irq -s", \&f_generic, 0, "IRQ STATS FOR ALL CPUS"],
	["kmem -i", \&f_generic, 0, "MEMINFO"],
	["kmem -s", \&f_generic, 0, "SLABINFO"],
	["kmem -v", \&f_generic, 0, "VMALLOCINFO"],
	["kmem -V", \&f_generic, 0, "VM STAT AND EVENTS"],
	["kmem -z", \&f_generic, 0, "ZONEINFO"],
	["log", \&f_generic, 0, "KERNEL LOG"],
	["mod", \&f_generic, 0, "MODULE INFO"],
	["mod -t", \&f_generic, 0, "MODULE TAINT INTO"],
	["mount", \&f_generic, 0, "MOUNTED FILESYSTEM INFO"],
#	["mount -f", \&f_generic, 0, "DENTRIES AND INODES FOR OPEN FILES"],
	["net", \&f_generic, 0, "NETWORK DEVICE LIST"],
	["net -a", \&f_generic, 0, "NET: ARP CACHE"],
	["ps -k", \&f_generic, 0, "KERNEL THREADS"],
#	["ps -u", \&f_generic, 0, "USER TASKS"],
	["ps -t", \&f_generic, 0, "TASK RUN TIME, START TIME, CUMULATIVE TIMES"],
	["ps -l", \&f_generic, 0, "TASKS: MOST RECENTLY RUN"],
	["runq -g", \&f_generic, 0, "RUN QUEUE"],
#	["swap", \&f_generic, 0, "SWAP INFO"],
	["timer", \&f_generic, 0, "TIMER INFO"],
	["timer -r", \&f_generic, 0, "HRTIMER INFO"],
	["kmem -S", \&f_generic, 1, 0],
	["kmem -F", \&f_generic, 1, 0],
	["kmem -p", \&f_generic, 1, 0],
	["dummy", \&f_dummy, 0],
	# The dummy command is used to identify the end
	# of raw bug report. So never add anything after this.
);

# Add all new commands here.
my @bypass_commands = (
	["bugreport",	\&f_bugreport,		"Generates bug_report.txt in the current folder\n".
						"usage:\n".
						"extscript -b bugreport\n"],
	["vmallocinfo", \&f_vmallocinfo,	"Disaplays vmallocinfo similar to /proc/vmallocinfo\n".
						"usage:\n".
						"extscript -b vmallocinfo\n"],
	["valtext",	\&f_valtext,		"Compares the .text and .rodata sections of ramdump and vmlinux\n".
						"Only for arm\n".
						"Pass the toochain path as comma seperated argument.\n".
						"usage:\n".
						"extscript -b valtext,/home/toochain/arm-eabi/bin/\n"],
	["help",	\&f_help,		"Displays this help\n".
						"extscript -b help\n"],
);

# The socket to communicate with
# crash utility.
my $perlfc_socket_path = "extscriptfcsocket";
my $perlfc_sock;
my $pfcs;

# The command output created by crash
# utility.
my $command_out = "./command.out";
my $rdfd;

# raw bug report created by perlfc
my $raw_bug_report = "./rawbugreport.txt";
my $rbfd;

# The bug report generated by perfc
my $bug_report = "./bug_report.txt";
my $brfd;

my $crash_prompt = "crash> ";

my $last_command;
my $command_begin;

sub cleanup {
	unlink($perlfc_socket_path);
	unlink($command_out);
	unlink($raw_bug_report);
}

sub sigint_handler
{
	print "perlfc: FATAL: SIGINT received\n";
	print "perlfc: THE LAST EXECUTED COMMAND WAS $last_command\n";
	print "THE ERROR IS USUALLY BECAUSE OF CRASH ENCOUNTERING A FATAL ERROR ON EXECUTING A COMMAND\n";
	print "TRY THE COMMAND STANDALONE FOR MORE CLUES\n";
	print "IF THIS HAD HAPPENED DURING A BUGREPORT, YOU MAY PROCEED BY UNCOMMENTING THE COMMAND IN THE SCRIPT COMMAND TABLE\n";
	cleanup();
	exit 0;
}

$SIG{INT} = "sigint_handler";

# The begining.
c_bind();

# Core funtions

sub perlfc_error
{
	print "perlfc.pl v$VERSION encounterd an error at $_[0]\n";
	send_command("DONE");
	wait_for_command();
	cleanup();
	exit 0;
}

sub c_bind
{
# Establish connection with crash utility.

	unlink($perlfc_socket_path);
	$pfcs = IO::Socket::UNIX->new(
		Local  => $perlfc_socket_path,
		Type   => SOCK_STREAM,
		Listen => SOMAXCONN,
	);

	die perlfc_error(__LINE__) unless $pfcs;

	$perlfc_sock = $pfcs->accept;
	$perlfc_sock->autoflush(1);

	wait_for_command();

	# wait for shutdown
	wait_for_command();
	cleanup();
}

sub send_command
{
	print $perlfc_sock $_[0];

	if ($_[0] eq "EXECUTECOMMAND") {
		$last_command = ":";
		$command_begin = 1;
	} elsif ($_[0] eq "ENDOFCOMMAND") {
		$command_begin = 0;
	} elsif ($command_begin && ($_[0] ne "ACK")) {
		$last_command = $last_command." ".$_[0];
	}

	if ($_[0] eq "ACK") {
		$perlfc_sock = $pfcs->accept;
		$perlfc_sock->autoflush(1);
	} else {
		# ACK
		wait_for_command();
	}
}

sub send_commands_list
{
	my $i;
	my $j;
	my @com;
	my $com_size;
	my $line;
	my $commands_size = scalar(@commands);

	for ($i = 0; $i < $commands_size; $i++) {
		@com = split(/ /,$commands[$i][0]);
		$com_size = scalar(@com);

		send_command("EXECUTECOMMAND");
		for ($j = 0; $j < $com_size; $j++) {
			send_command($com[$j]);
		}
		send_command("ENDOFCOMMAND");
		$com = <$perlfc_sock>;
		if ($com eq "COMMANDEXECUTED") {
			send_command("ACK");
			open($rdfd, "<", $command_out)
				or perlfc_error(__LINE__);
			print $rbfd $crash_prompt.$commands[$i][0]."\n";
			while($line = <$rdfd>) {
				print $rbfd $line;
			}
			close($rdfd);
		} else {perlfc_error(__LINE__);}
		print $rbfd "\n";
	}
}

sub open_command
{
	my $count = 0;
	my $line;
	my $com;
	my $rdfd;

	send_command("EXECUTECOMMAND");
	foreach my $arg (@_) {
		if (!$count) {
			$line = $_[0];
			$count++;
			next;
		}
		send_command($_[$count]);
		$count++;
	}
	send_command("ENDOFCOMMAND");

	$com = <$perlfc_sock>;
	if ($com eq "COMMANDEXECUTED") {
		send_command("ACK");
		open($rdfd, "<", $command_out)
			or perlfc_error($line);
	} else {perlfc_error($line);}

	return $rdfd;
}

sub close_command
{
	close $_[0];
}

sub exec_bypass
{
	my $com;
	my $by_com_size = scalar(@bypass_commands);
	my $i;
	my @arr;

	$com = <$perlfc_sock>;
	send_command("ACK");

	# crash bypasses the args in comma seperated
	# format.
	@arr = split(/,/,$com);

	for ($i = 0; $i < $by_com_size; $i++) {
		if ($arr[0] eq $bypass_commands[$i][0]) {
			&{$bypass_commands[$i][1]}(@arr);
			last;
		}
	}

	if ($i == $by_com_size) {
		print "perlfc: command not found\n";
	}

	send_command("DONE");
}

sub wait_for_command
{
	my $com = <$perlfc_sock>;

	if ($com eq "BYPASS") {
		send_command("ACK");
		exec_bypass($com);
	} elsif ($com eq "ACK") {
		send_command("ACK");
	} elsif ($com eq "SHUTDOWN") {
		send_command("ACK");
	}
}

sub write_till_next_com
{
	my $line;
	while (1) {
		$line = <$rbfd>;
		if ($line =~ /crash> /) {
			if ($_[0] == 0) {
				print $brfd "\n\n";
			}
			seek $rbfd, 0,SEEK_SET;
			last;
		}
		if ($_[0] == 0) {
			print $brfd $line;
		} elsif ($_[0] == 1) {
			if (($line =~ /ERROR/) ||
				($line =~ /error/) ||
				($line =~ /WARN/) ||
				($line =~ /warn/)) {
					print $brfd $commands[$_[1]][0]."::".$line;
				}
		}
	}
}

sub print_com_header
{
	my $i;
	my $length;
	if ($_[0] == 0) {
		print $brfd $commands[$_[1]][3]."\n";
		$length = length($commands[$_[1]][3]);
		for ($i = 0; $i < $length; $i++) {
			print $brfd "-";
		}
		print $brfd "\n";
	}
}

sub f_help
{
	my $i;
	my $sizebypass = scalar(@bypass_commands);
	print "-------------------------\n";
	print "perlfc: version:$VERSION\n\n";
	print "HELP:\n\n";
	for ($i = 0; $i < $sizebypass; $i++) {
		print "[$bypass_commands[$i][0]]:\n$bypass_commands[$i][2]\n";
	}
}

# helper funtions for each command in the command table.

sub f_hex
{
	#Nothing to be done.
}

sub f_generic
{
	print_com_header($_[0], $_[1]);
	write_till_next_com($_[0], $_[1]);
}

sub f_dummy
{
	#End of report
	#Do nothing
}

sub br_write_header
{
	print $brfd "BUG REPORT\n";
	print $brfd "----------\n\n";
}

sub process_raw_dumpstate
{
	my $i = 0;
	my $match;
	my $line;

	open($rbfd, "<", $raw_bug_report)
		or perlfc_error(__LINE__);

	open($brfd, ">", $bug_report)
		or perlfc_error(__LINE__);

	br_write_header();

	print $brfd "ERROR SUMMARY\n";
	print $brfd "-------------\n";

	# Loop once to capture the errors
	$match = $crash_prompt.$commands[$i][0];
	while($line = <$rbfd>) {
		if ($line =~ /$match/) {
			# Pass 1 as first argument to
			# process errors.

			&{$commands[$i][1]}(1, $i);
			$i++;
			$match = $crash_prompt.$commands[$i][0];
		}
	}

	print $brfd "\n";

	# then to generate the report
	$i = 0;
	seek $rbfd, 0,SEEK_SET;
	$match = $crash_prompt.$commands[$i][0];
	while($line = <$rbfd>) {
		if (($line =~ /$match/) && ($commands[$i][2] != 1)) {
			# Pass 0 as first arg to
			# to generate the bug report.

			&{$commands[$i][1]}(0, $i);
			$i++;
			$match = $crash_prompt.$commands[$i][0];
		}
	}

	close $rbfd;
	close $brfd;
}

sub f_bugreport
{
	print "Generating bug report...May take around 5 mins depending on the machine speed, and commands in command table\n";
	print "DESELECT UNNECESSARY COMMANDS IN THE COMMAND TABLE TO REDUCE EXEC TIME\n";

	open($rbfd, ">", $raw_bug_report)
		or perlfc_error(__LINE__);

	send_commands_list();

	close($rbfd);

	process_raw_dumpstate();

	print "Dont worry about the \"dummy\" command error\n";
	print "Bug report (bug_report.txt) created in the current folder\n";
}

sub f_vmallocinfo
{
	my $rdfd;
	my $line;
	my $tmpfd;

	print "Generating vmallocinfo(address range, size, caller)...\n";

	$rdfd = open_command(__LINE__, "set", "radix", "16");
	close_command($rdfd);

	$rdfd = open_command(__LINE__, "kmem", "-v");

	open($tmpfd, "+>", "./temp")
		or perlfc_error(__LINE__);

	while($line = <$rdfd>) {
		print $tmpfd $line;
	}

	seek $tmpfd, 0,SEEK_SET;
	close_command($rdfd);

	# skip the first line
	$line = <$tmpfd>;
	while ($line = <$tmpfd>) {
		my @divide = split(' ', $line);
		#print "$divide[0], $divide[1], $divide[2], $divide[3], $divide[4], $divide[5]\n";

		$rdfd = open_command(__LINE__, "struct", "vm_struct.caller", $divide[1]);
		$line = <$rdfd>;
		my @divide1 = split(' ', $line);
		#print "$divide1[0], $divide1[1], $divide1[2], $divide1[3], $divide1[4], $divide1[5]\n";
		close_command($rdfd);

		$rdfd = open_command(__LINE__, "sym", $divide1[2]);
		$line = <$rdfd>;
		my @divide2 = split(' ', $line);
		if ($divide2[1] eq "invalid") {
			$divide2[2] = 0;
		}

		printf "%s - %s\t%15s\t%75s\n", $divide[2], $divide[4], $divide[5], $divide2[2];
		close_command($rdfd);
	}

	close($tmpfd);
}

sub f_valtext
{
	my $tools_path;
	my $vmlinux_path;
	my $vmlinux_text = "./vmlinux_text.bin";
	my $objcopy_string;
	my $com;
	my $line;
	my @arr;
	my $_text;
	my $_etext;
	my $_rodata;
	my $_erodata;
	my $rawtextpath = "./rawtext.bin";
	my $readelf_temp = "./readelf.txt";
	my $readelf;
	my $tfd;

	print "Validating text...Wait\n";
	# read the path of tools (for readelf and objcopy)
	my $tools_path = $_[1];

	# read the vmlinux path
	send_command("VMLINUXPATH");
	my $vmlinux_path = <$perlfc_sock>;
	send_command("ACK");

	$readelf = $tools_path."/"."arm-eabi-readelf -S ".$vmlinux_path." > ".$readelf_temp;
	system($readelf) == 0 or perlfc_error(__LINE__);
	open($tfd, "<", $readelf_temp)
		or die perlfc_error(__LINE__);
	# Parse the readelf output to get the start and size corresponding
	# to .text and .rodata.
	# Usual output line looks like this.
	# [ 2] .text             PROGBITS        c0008180 008180 6320c0 00  AX  0   0 64
	#
	while ($line = <$tfd>) {
		if ($line =~ / .text /) {
			@arr = split(' ', $line);
			$_text = $arr[4];
			$_etext = hex($_text) + hex($arr[6]);
			$_etext = sprintf("%x", $_etext);
		} elsif ($line =~ / .rodata /) {
			@arr = split(' ', $line);
			$_rodata = $arr[4];
			$_erodata = hex($_rodata) + hex($arr[6]);
			$_erodata = sprintf("%x", $_erodata);
			last;
		}

	}
	close($tfd);

#	$objcopy_string = $tools_path."/"."arm-eabi-objcopy ".
#		"-S -O binary -R .init.text -R .exit.text -R ".
#		"init.proc.info -R .init.arch.info -R ".
#		"init.tagtable -R .init.data -R .data -R .notes -R .bss ".
#		"-R .data..percpu ".
#		$vmlinux_path." ".$vmlinux_text;

#	$objcopy_string = $tools_path."/"."arm-eabi-objcopy ".
#		"-S -O binary -j .head.text ".
#		"-j .text -j APPF ".
#		"-j APPF_ENTRY_POINT_ ".
#		"-j .rodata ".
#		"-j __bug_table -j __ksymtab ".
#		"-j __ksymtab_gpl -j __kcrctab ".
#		"-j __kcrctab_gpl -j __ksymtab_strings ".
#		"-j __init_rodata -j __param ".
#		"-j __modver -j .ARM.unwind_idx ".
#		"-j .ARM.unwind_tab ".
#		$vmlinux_path." ".$vmlinux_text;
	# text
	$objcopy_string = $tools_path."/"."arm-eabi-objcopy ".
		"-S -O binary ".
		"-j .text ".
		$vmlinux_path." ".$vmlinux_text;

	system($objcopy_string);

	$rdfd = open_command(__LINE__, "rd", $_text, "-e", $_etext, "-r", $rawtextpath);
	close_command($rdfd);
	if (compare($rawtextpath, $vmlinux_text) == 0) {
		print "The text section is intact\n";
	} else {
		print "ERROR: text section of ramdump".
			" not matching with vmlinux text\n";
	}

	# rodata compare
	$objcopy_string = $tools_path."/"."arm-eabi-objcopy ".
		"-S -O binary ".
		"-j .rodata ".
		$vmlinux_path." ".$vmlinux_text;

	system($objcopy_string);

	$rdfd = open_command(__LINE__, "rd", $_rodata, "-e", $_erodata, "-r", $rawtextpath);
	close_command($rdfd);
	if (compare($rawtextpath, $vmlinux_text) == 0) {
		print "The rodata section is intact\n";
	} else {
		print "ERROR: rodata section of ramdump".
			" not matching with vmlinux rodata\n";
	}

	unlink($rawtextpath);
	unlink($readelf_temp);
	unlink($vmlinux_text);
}
