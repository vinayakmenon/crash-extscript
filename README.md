crash-extscript
===============

Extension module for crash utility to talk to external scripts

What is extscript utility for ?
       At times we need to execute a series of crash
commands to arrive at a result. i.e. we execute a command,
get the output, pick an element from it, use it with the
next command and so on. There are cases were this may take
several steps. So this utility is to automate these steps.
Another use can be to execute a series of predefined crash commands
to generate a bug report kind of thing.

A brief on the components in this package.
(1) A crash utility extension called 'extscript'.
     This provides a crash command of the same name.
(2) A script. perlfc.pl is an example script.
(3) A protocol definition, for communication
   between 'extscript' and the external script.

The external script is run as a server by crash utility, when you
invoke the extscript command.
The external script serves the crash utility by additonal commands.
The script is not executed as is. We invoke the script from crash
command line. In other words, we talk to the script from within
the crash utility command line.

An example.
crash> extscript -f perl -a perl -a ./perlfc.pl
crash> extscript -b bugreport

The first command sets up the environement. This is
similar to how we pass arguments to execlp. The last
argument is the script. This command has to be modified
depoending on the kind of script that we are running.
The second command is the bypass command which actually
executes the command we have encoded in the script.
In this case "bugreport" is a command that is defined in
perlfc.pl. The extecript bypasses this command to the
script. The output in this case will be a bug_report.txt.
And in other cases the output will be directly printed to
crash console. Thus in simple words we are extending crash
with additoinal commands encoded in a script.

The perlfc.pl script is an example of how to use the
extscript extension of crash utility. Using the
extscript extension, crash utility can connect to
an external server. The server can send the commands
to be executed, over a socket, to crash utility and
get the output back. The ouput can be manipulated inside
the script, and using a series of commands we can
generate useful outputs, that takes time when done manually
through crash command line.

A generic use case can be something of this sort.
(1) Write a funtion in this or any script which obeys the protocol.
(2) The funtion sends a "crash utility command" to crash utility.
(3) The crash utility client (extscript) receives it and executes it.
(4) The output is written to ./command.out.
(5) This script parses the output and takes out what it needs.
(6) From what it has derived from (5), sends the next command to crash
   utility. This goes on.

How to add a new command ?:
Add the following to the "bypass_commands" table.
(1) command tag to be set as argument to perlfc,
(2) help
(3) the corresponding funtion address.
Done.

All scripts must implement a help command.
All scripts must implement a SIGINT signal handler. In the handler
necessary cleanup has to be performed and exit.

Protocol between crash and perlfc:
The socket should match that of crash utility ("extscriptfcsocket").

Note:
     p->c : perl to crash
     c->p : crash to perl
(1) Every command send by crash must be
    acked by perl (including an ACK from crash).
(2) crash will not send an ACK for an ACK.
(3) If a crash utility command has to be send to crash
    for execution, it has to be in the following format.
    ACKs not specified.

   p->c: "EXECUTECOMMAND"
   p->c: command split
   p->c: "ENDOFCOMMAND"
   c->p: "COMMANDEXECUTED"

EXAMPLE: "kmem -i"
   p->c: "EXECUTECOMMAND"
   p->c: "kmem"
   p->c: "-i"
   p->c: "ENDOFCOMMAND"
   c->p: "COMMANDEXECUTED"

Currently the output of crash is received via ./command.out
and not through the socket.

VMLINUXPATH command can be send to crash to get the
path to vmlinux.

(4) A command should be a single string without any space
    or special characters.

(5) crash sends the BYPASS command followed by a string
    containing the command to process and args.
    perl should send DONE command after procesing is
    completed.

(6) perl should wait for SHUTDOWN command from crash
    before exiting.
