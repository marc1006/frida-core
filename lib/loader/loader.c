#ifdef HAVE_IOS

#include <assert.h>
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define FRIDA_LOADER_DATA_DIR_MAGIC "3zPLi3BupiesaB9diyimME74fJw4jvj6"

typedef void (* FridaAgentMainFunc) (const char * data_string, void * mapped_range, size_t parent_thread_id);

static void * frida_loader_run (void * user_data);
static bool frida_loader_send (int s, const char * format, ...);
static bool frida_loader_send_value (int s, const char * v);
static bool frida_loader_send_bytes (int s, const void * bytes, size_t size);
static char * frida_loader_recv_value (int s);
static bool frida_loader_recv_bytes (int s, void * bytes, size_t size);

static char frida_data_dir[256] = FRIDA_LOADER_DATA_DIR_MAGIC;

#include <stdio.h>

static void
frida_log (const char * format, ...)
{
  FILE * f;
  va_list vl;

  f = fopen ("/private/var/mobile/Containers/Data/Application/286C7ECF-2AD6-4E83-B9B7-8A2BCC38E589/tmp/loader.log", "ab");
  if (f != NULL)
  {
    va_start (vl, format);
    vfprintf (f, format, vl);
    va_end (vl);
    fclose (f);
  }
}

__attribute__ ((constructor)) static void
frida_loader_on_load (void)
{
  char * callback_path;
  int s;
  struct sockaddr_un callback;
  char * pipe_address, * permission_to_resume;
  pthread_t thread;

  frida_log ("frida_loader_on_load\n");

  asprintf (&callback_path, "%s/callback", frida_data_dir);

  s = socket (AF_UNIX, SOCK_STREAM, 0);
  if (s == -1)
    goto beach;

  callback.sun_len = sizeof (callback.sun_len) + sizeof (callback.sun_family) + strlen (callback_path);
  callback.sun_family = AF_UNIX;
  strcpy (callback.sun_path, callback_path);
  if (connect (s, (struct sockaddr *) &callback, callback.sun_len) == -1)
    goto beach;

  if (!frida_loader_send (s, "%d", getpid ()))
    goto beach;

  pipe_address = frida_loader_recv_value (s);
  if (pipe_address == NULL)
    goto beach;

  pthread_create (&thread, NULL, frida_loader_run, pipe_address);
  pthread_detach (thread);

  permission_to_resume = frida_loader_recv_value (s);
  free (permission_to_resume);

beach:
  if (s != -1)
    close (s);

  free (callback_path);
}

static void *
frida_loader_run (void * user_data)
{
  char * pipe_address = user_data;
  char * agent_path;
  void * agent;
  FridaAgentMainFunc agent_main;

  asprintf (&agent_path, "%s/frida-agent.dylib", frida_data_dir);

  agent = dlopen (agent_path, RTLD_GLOBAL | RTLD_LAZY);
  if (agent == NULL)
    goto beach;

  agent_main = (FridaAgentMainFunc) dlsym (agent, "frida_agent_main");
  assert (agent_main != NULL);

  agent_main (pipe_address, NULL, 0);

  dlclose (agent);

beach:
  free (agent_path);

  free (pipe_address);

  return NULL;
}

static bool
frida_loader_send (int s, const char * format, ...)
{
  bool success;
  va_list vl;
  char * v;

  va_start (vl, format);
  vasprintf (&v, format, vl);
  success = frida_loader_send_value (s, v);
  free (v);
  va_end (vl);

  return success;
}

static bool
frida_loader_send_value (int s, const char * v)
{
  uint8_t size = strlen (v);
  if (!frida_loader_send_bytes (s, &size, sizeof (size)))
    return false;

  return frida_loader_send_bytes (s, v, size);
}

static bool
frida_loader_send_bytes (int s, const void * bytes, size_t size)
{
  size_t offset = 0;

  while (offset != size)
  {
    ssize_t n;

    n = send (s, bytes + offset, size - offset, 0);
    if (n != -1)
      offset += n;
    else if (errno != EINTR)
      return false;
  }

  return true;
}

static char *
frida_loader_recv_value (int s)
{
  uint8_t size;
  char * buf;

  if (!frida_loader_recv_bytes (s, &size, sizeof (size)))
    return NULL;

  buf = malloc (size);
  if (!frida_loader_recv_bytes (s, buf, size))
  {
    free (buf);
    return NULL;
  }

  return buf;
}

static bool
frida_loader_recv_bytes (int s, void * bytes, size_t size)
{
  size_t offset = 0;

  while (offset != size)
  {
    ssize_t n;

    n = recv (s, bytes + offset, size - offset, 0);
    if (n > 0)
      offset += n;
    else if (n == 0)
      return false;
    else if (n == -1 && errno != EINTR)
      return false;
  }

  return true;
}

#endif
