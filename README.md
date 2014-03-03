crash-extscript
======================================

Extension module for crash utility, to talk to external scripts

What is extscript utility for ?
       At times we need to execute a series of crash
commands to arrive at a result. i.e. we execute a command,
get the output, pick an element from it, use it with the
next command and so on. There are cases when this may take
several steps. This utility is to automate these steps.
Another use can be to execute a series of predefined crash commands,
parse it to get relevant info and to generate a bug report.

A brief on the components in this package.
(1) A crash utility extension called 'extscript'.
    This provides a crash command of the same name.
(2) A script. perlfc.pl is an example script, which can talk to
    extscript extension. This script can be used as an example
    to write utilities that can talk to extscript extension.
(3) A protocol definition, for communication
   between 'extscript' and the external script.

The external script is run as a server by crash utility, when you
invoke the extscript command.
The external script serves the crash utility by additonal commands.
The script is not executed as is. We invoke the script from crash
command line. In other words, we talk to the script from within
the crash utility command line.

An example.
(1) Copy the extscript.c to extensions folder
(2) make extensions
(3) Copy perlfc.pl to crash directory.

crash> extend extensions/extscript.so
crash> extscript -f perl -a perl -a ./perlfc.pl
crash> extscript -b vmallocinfo
crash> extscript -b help

The first command loads the extscript module and adds the
command "extscript" to crash utility.
The second command sets up the environement. This is
similar to how we pass arguments to execlp. The last
argument is the script path. This command has to be modified
depending on the kind of script that we are running.
The third command is the bypass command which actually
executes the command we have encoded in the script.
In this case "vmallocinfo" is a command that is defined in
perlfc.pl. The extecript bypasses this command to the
script. The output in this case will be vmallocinfo similar
/proc/vmallocinfo, displayed on crash console.
Thus in simple words we are extending crash
with additoinal commands encoded in a script.
The "help" command shows all the commands supported by
the script and its usage.

The perlfc.pl script is an example of how to use the
extscript extension of crash utility. Using the
extscript extension, crash utility can connect to
an external server. The server can send the commands
to be executed, over a socket, to crash utility and
get the output back. The ouput can be manipulated inside
the script, and using a series of commands we can
generate useful outputs, which takes time when done manually
through crash command line.

A generic use case can be something of this sort.
(1) Write a funtion in the script which obeys the protocol.
(2) The funtion sends a "crash utility command" to crash utility.
(3) The crash utility client (extscript) receives it and executes it.
(4) The output is written to ./command.out.
(5) This script parses the output and takes out what it needs.
(6) From what it has derived from (5), sends the next command to crash
   utility. This goes on.

perlf.pl can be considered as a reference to implement new scripts,
and to understand the protocol (see c_bind funtion).

How to add a new command ?:
Add the following to the "bypass_commands" table.
(1) command tag to be set as argument to perlfc,
(2) help
(3) the corresponding funtion address.
Done.
A good example can be the vmallocinfo implementation in
perlfc.pl

Output example:
The "vmallocinfo" command gives an output like shown below.

-----------------8<-----------------------------------------------------------------------------------------------
crash> extscript -b vmallocinfo
Generating vmallocinfo(address range, size, caller)...
bf000000 - bf04f000              323584                                             module_alloc_update_bounds+0x1c
bf05f000 - bf064000               20480                                             module_alloc_update_bounds+0x1c
f0002000 - f0004000                8192                                                 NewVMallocLinuxMemArea+0xf0
f0004000 - f0045000              266240                                                            atomic_pool_init

......

----------------------------------->8------------------------------------------------------------------------------

General rules:
All scripts must implement a help command.
All scripts must implement a SIGINT signal handler. In the handler
necessary cleanup has to be performed before exit.

Protocol between crash and perlfc:
The socket should match that of crash utility ("extscriptfcsocket").

Notes on terminology:
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
    containing the command to process plus args.
    Script should send DONE command after procesing is
    completed.

(6) Script should wait for SHUTDOWN command from crash
    before exiting.

-Vinayak
