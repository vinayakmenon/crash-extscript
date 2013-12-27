/* extscript.c - external script support for crash
 *
 * Copyright (C) 2013 Vinayak Menon<vinayakm.list@gmail.com>.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * Crash can talk to an external script using this extension.
 * See perlfc.pl for an usage example and the protocol definition.
 */
#include "defs.h"
#include <sys/types.h>
#include <unistd.h>
#include <setjmp.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <signal.h>

#define EXTSCRIPTFC_SOCKET	"extscriptfcsocket"
#define COMMAND_OUT_FILE	"./command.out"

#define MAX_COMMAND_SIZE	100
#define MAX_COMMAND_SPLIT	50

#define DONE 2
#define CONNECT_RETRIES 10000

static int extscriptfc_debug = 0;
#define DEBUG(args...)				\
	do {					\
		if(extscriptfc_debug)		\
			fprintf(stdout, args);	\
	} while(0)				\

#define MAX_ARGS 2
#define MAX_ARG_SIZE 200

static int fd_sock_comm;
static FILE *ofile;
static char *bypass_arg;
static char *comm[MAX_COMMAND_SPLIT];
static char execlp_file[MAX_COMMAND_SIZE];
static char execlp_arg[MAX_ARGS][MAX_COMMAND_SIZE];
static int bflag;
static pid_t extscriptfc_pid;
static struct sockaddr_un local;
static jmp_buf saved_jmp_buf;

static int send_command(const char* com);
static int extscript_bind(void);
static void extscript_unbind(void);
static int wait_and_process_command(void);
static void execute_crash_command(void);
static void extscript_process(void);
static void cleanup(void);

void extscript_init(void);
void extscript_fini(void);

void cmd_extscript(void);
char *help_extscript[];

static struct command_table_entry command_table[] = {
	{ "extscript", cmd_extscript, help_extscript, 0},
	{ NULL },
};

void __attribute__((constructor))
extscript_init(void)
{
	register_extension(command_table);
}

void __attribute__((destructor))
extscript_fini(void) { }

/*
 * crash and extscriptfc command definiton.
 *
 * Rules:
 * 1) All commands should be a string
 *    without any space.
 * 2) extscript must ack each and every
 *    command send to it, including
 *    an ACK.
 * 3) The max command size is defined as
 *    100.
 */
void cmd_extscript(void)
{
	int c;
	int len;
	int arg_cnt = 0;

        while ((c = getopt(argcnt, args, "b:f:a:")) != EOF) {
                switch(c)
		{
		case 'b':
			/* bypass command */
			bflag = 1;
			DEBUG("bflag is set\n");
			bypass_arg = optarg;
			break;
		case 'f':
			/* set the execlp file */
			len = strlen(optarg) + 1;
			if (len > MAX_ARG_SIZE) {
				error(INFO, "arg not allowed to be > %d\n",
					MAX_ARG_SIZE);
				return;
			}
			strncpy(execlp_file, optarg, len);
			break;
		case 'a':
			/* set the execlp args */
			if (arg_cnt < MAX_ARGS) {
				len = strlen(optarg) + 1;
				if (len > MAX_ARG_SIZE) {
					error(INFO, "arg not allowed to be > %d\n",
						MAX_ARG_SIZE);
					return;
				}
				strncpy(execlp_arg[arg_cnt], optarg, len);
				++arg_cnt;
			} else {
				error(INFO, "Only %d args allowed\n", MAX_ARGS);
				return;
			}
			break;
		default:
			argerrs++;
			break;
		}
	}

	if (!bflag)
		return;

	if (argerrs)
		cmd_usage(pc->curcmd, SYNOPSIS);

	/* At least this should not be NULL */
	if (!execlp_arg[0][0]) {
		error(INFO, "script path is not set\n");
		return;
	}

	/*
	 * Crash utility on occurence of a fatal error
	 * does a restart by jumping to the main loop.
	 * But this is a problem for us because, we
	 * would have overridden the "fp", and thus
	 * jumping to main loop can result in a pseudo
	 * hang. To overcome this we have to add a new
	 * jump buffer, like the foreach and add
	 * a branch to this in _error(). But this means
	 * a modification to the crash utility code.
	 * To avoid this, what we do here is something
	 * not really correct. But it works. Just before
	 * branching to exec_command, the main_loop_env
	 * is overridden, and is restored later using this
	 * saved copy.
	 */
	memcpy(saved_jmp_buf, pc->main_loop_env, sizeof(jmp_buf));

	if (extscript_bind()) {
		error(INFO, "extscript bind failed\n");
		return;
	}

	bflag = 0;
	extscript_unbind();
}

static int send_command(const char* com)
{
	size_t size = 0;
	DEBUG("sc: %s\n", com);

	size = strlen(com);
	if (0 > send(fd_sock_comm, com, size, 0)) {
		error(INFO, "failed to write command %s\n", com);
		return -1;
	}

	DEBUG("sc: shutdown\n");

	shutdown(fd_sock_comm, SHUT_WR);
	/* Note that we wait here even for an ACK sent.
	 * extscript alone should ack for an ack.
	 */
	wait_and_process_command();
	return 0;
}

static void cleanup(void)
{
	int i;

	close(fd_sock_comm);
	bflag = 0;
	for(i = 0; comm[i]; i++)
		free(comm[i]);
}

static void execute_crash_command(void)
{
	int bak;
	int status;
	FILE* old_fp = fp;

	if ((ofile =
		fopen(COMMAND_OUT_FILE, "w+")) == NULL) {
		error(INFO, "unable to open %s\n", COMMAND_OUT_FILE);
		return;
	}

	setbuf(ofile, NULL);
	fp = pc->ofile = ofile;

	/*
	 * Crash writes the errors and warnings to stdout.
	 * We want it to be redirected for the use of extscriptfc.
	 * dup it.
	 */
	fflush(stdout);
	bak = dup(1);
	dup2(fileno(ofile), 1);

	if (setjmp(pc->main_loop_env)) {
		memcpy(pc->main_loop_env, saved_jmp_buf, sizeof(jmp_buf));
		fflush(stdout);
		dup2(bak, 1);
		close(bak);
		fclose(ofile);
		pc->ofile = NULL;
		fp = stdout;
		cleanup();
		kill(extscriptfc_pid, SIGINT);
		waitpid(extscriptfc_pid, &status, 0);
		longjmp(pc->main_loop_env, 1);
	}

	exec_command();

	fflush(stdout);
	dup2(bak, 1);
	close(bak);

	fclose(ofile);
	pc->ofile = NULL;
	fp = old_fp;
}

static int crash_receive_execute_command(void)
{
	char command[MAX_COMMAND_SIZE];
	int ret = 0;
	int i;

	memset(comm, 0, MAX_COMMAND_SPLIT);
	DEBUG("%s, %d\n", __func__, __LINE__);

	for(i = 0, argcnt = 0, (ret = recv(fd_sock_comm,
			command, MAX_COMMAND_SIZE - 1, 0)),
		send_command("ACK");
		(strncmp(command, "ENDOFCOMMAND", 12)) && (ret > -1);
		(ret = recv(fd_sock_comm, command, MAX_COMMAND_SIZE, 0)),
			send_command("ACK"), i++) {

		command[ret] = '\0';
		comm[i] = (char*)malloc(MAX_COMMAND_SIZE);
		if (!comm[i]) {
			error(INFO, "malloc failed\n");
			ret = -1;
			goto error;
		}
		strncpy(comm[i], command, ret + 1);
		DEBUG("%s: args:%s:%d\n", __func__, command, i);
		args[i] = comm[i];
		DEBUG("%s: argscopied:%s\n", __func__, args[i]);
		argcnt++;
	}

	args[argcnt] = '\0';

	DEBUG("%s, %d\n", __func__, __LINE__);
	if (ret == EOF) {
		ret = -1;
		goto error;
	}

	DEBUG("%s, %d\n", __func__, __LINE__);
	execute_crash_command();

	DEBUG("%s, %d\n", __func__, __LINE__);
	send_command("COMMANDEXECUTED");

	ret = 0;

error:
	for(i = 0; comm[i]; i++)
		free(comm[i]);

	return ret;
}

static int wait_and_process_command(void)
{
	char command[MAX_COMMAND_SIZE];
	int len;
	int retry = 0;
	int ret;

	DEBUG("%s, %d\n", __func__, __LINE__);
	/* Note that we expect a single string command
	 * without space.
	 */
	if (0 > (ret = recv(fd_sock_comm, command, MAX_COMMAND_SIZE - 1, 0))) {
		error(INFO, "recv failed %s\n", strerror(errno));
		return -1;
	}

	command[ret] = '\0';
	DEBUG("%s: received: %s\n", __func__, command);
	if (!strncmp(command, "EXECUTECOMMAND", 14)) {

		send_command("ACK");

		DEBUG("%s, %d\n", __func__, __LINE__);
		if (crash_receive_execute_command())
			return -1;
	} else if (!strncmp(command, "VMLINUXPATH", 14)) {

		send_command("ACK");

		DEBUG("%s, %d\n", __func__, __LINE__);
		if (send_command(pc->namelist))
			return -1;
	} else if (!strncmp(command, "DONE", 4)) {

		DEBUG("%s, %d\n", __func__, __LINE__);
		/* extscriptfc has exited or about to exit */
		send_command("ACK");
		return DONE;
	} else if (!strncmp(command, "ACK", 3)) {

		/*
		 * We do a shutdown and close everytime to
		 * workaround the flush issues with socket.
		 * Setting socket options doesn't work on all
		 * environments. This is found to be the most
		 * reliable way to flush the socket.
		 */
		len = strlen(local.sun_path) + sizeof(local.sun_family);

		shutdown(fd_sock_comm, SHUT_RD);
		close(fd_sock_comm);
		if ((fd_sock_comm = socket(AF_UNIX, SOCK_STREAM, 0)) == -1) {
			error(INFO, "failed to create socket\n");
			return -1;
		}

		local.sun_family = AF_UNIX;
		strcpy(local.sun_path, EXTSCRIPTFC_SOCKET);

		while (connect(fd_sock_comm, (struct sockaddr *)&local, len)) {
			if (++retry > CONNECT_RETRIES)
				break;
		}

		if (retry > CONNECT_RETRIES) {
			error(INFO, "connect failed\n");
			return -1;
		}

		DEBUG("%s, %d\n", __func__, __LINE__);
	}

	return 0;
}

static void extscript_process(void)
{
	int ret;

	DEBUG("%s, %d\n", __func__, __LINE__);
	if (bflag) {
		send_command("BYPASS");
		send_command(bypass_arg);
	}

	while(1) {
		ret = wait_and_process_command();
		if (ret)
			break;
	}
}

static void extscript_unbind(void)
{
	int status = 0;
	send_command("SHUTDOWN");
	waitpid(extscriptfc_pid, &status, 0);
	close(fd_sock_comm);
}

static int extscript_bind(void)
{
	int len;

	/* Create unix domain socket: comms b/w extscript and external ecript */

	if ((fd_sock_comm = socket(AF_UNIX, SOCK_STREAM, 0)) == -1) {
		error(INFO, "failed to create socket\n");
		return -1;
	}

	local.sun_family = AF_UNIX;
	strcpy(local.sun_path, EXTSCRIPTFC_SOCKET);

	/* Create a process to run extscript */
	if ((extscriptfc_pid = fork()) < 0) {
		error(INFO, "fork of extscriptfc failed\n");
		return -1;
	}

	if (extscriptfc_pid > 0) {
		sleep(1);
		len = strlen(local.sun_path) + sizeof(local.sun_family);
		if (connect(fd_sock_comm, (struct sockaddr *)&local, len) == -1) {
			error(INFO, "connect failed\n");
			return -1;
		}

		extscript_process();
	} else if (!extscriptfc_pid) {
		DEBUG("CHILD\n");
		execlp(execlp_file, execlp_arg[0], execlp_arg[1], NULL);
		error(INFO, "failed to start extscriptfc\n");
	}

	return 0;
}

char *help_extscript[] = {
	"extscript",
	"Execute external scripts from crash",
	"[-b] [-f] [-a]\n",

	"This command can be used to talk to an external script.",
	"	b : Used to bypass args to external script.",
	"	f : set the execlp style \"file\" arg for script execution.",
	"	a : set the execlp style \"arg\" for script execution.",
	"",
	"EXAMPLE\n",
	"First the script details has to be set.",
	"For e.g. to execute a perl script named perlfc.pl placed in curr dir, first do",
	"	extscript -f perl -a perl -a ./perlfc.pl",
	"After this, commands specific to external script can be issued using -b option",
	"To get the set of commands supported by the external script.",
	"extscript -b help",
	NULL
};
