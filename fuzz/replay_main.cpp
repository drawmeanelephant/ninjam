/*
    Standalone driver for the NINJAM fuzzer harness.

    Two jobs, both of which must exit nonzero on any sanitizer abort:
      1. run the API-level regression checks (regression_checks.cpp)
      2. replay every crash repro file given on the command line (normally the
         checked-in fuzz/corpus/crash-*.bin files)

    Built with ASan+UBSan+DEBUG_TIGHT_ALLOC, so if any of the parse-bounds fixes
    is reverted, replaying its repro aborts and the test fails.
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#ifndef _WIN32
#include <dirent.h>
#endif

extern "C" int LLVMFuzzerTestOneInput(const unsigned char *data, size_t size);
extern "C" int LLVMFuzzerInitialize(int *argc, char ***argv);
int run_regression_checks();

static int replay_file(const char *path)
{
  FILE *f = fopen(path, "rb");
  if (!f)
  {
    fprintf(stderr, "cannot open %s\n", path);
    return 2;
  }
  fseek(f, 0, SEEK_END);
  long len = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (len < 0 || len > (1<<20))
  {
    fprintf(stderr, "bad size for %s\n", path);
    fclose(f);
    return 2;
  }
  unsigned char *buf = (unsigned char *)malloc(len ? len : 1);
  if (fread(buf, 1, len, f) != (size_t)len)
  {
    fprintf(stderr, "short read on %s\n", path);
    fclose(f);
    free(buf);
    return 2;
  }
  fclose(f);

  printf("replaying %s (%ld bytes)\n", path, len);
  LLVMFuzzerTestOneInput(buf, len);
  free(buf);
  printf("ok        %s\n", path);
  return 0;
}

// if the argument is a directory, replay every crash-* file inside it
static int replay_arg(const char *path)
{
  struct stat st;
  if (stat(path, &st) != 0)
  {
    // no repros checked in (e.g. pristine tree): nothing to replay
    printf("skipping %s (not found)\n", path);
    return 0;
  }
  if (!(st.st_mode & S_IFDIR)) return replay_file(path);

#ifdef _WIN32
  fprintf(stderr, "directory replay unsupported on windows\n");
  return 2;
#else
  DIR *d = opendir(path);
  if (!d) return 2;
  struct dirent *e;
  int rc = 0;
  while ((e = readdir(d)))
  {
    if (strncmp(e->d_name, "crash-", 6)) continue;
    char full[1024];
    snprintf(full, sizeof(full), "%s/%s", path, e->d_name);
    int r = replay_file(full);
    if (r) rc = r;
  }
  closedir(d);
  if (!rc) printf("replayed all crash repros in %s\n", path);
  return rc;
#endif
}

int main(int argc, char **argv)
{
  LLVMFuzzerInitialize(&argc, &argv);

  int rc = run_regression_checks();

  for (int i = 1; i < argc; i++)
  {
    int r = replay_arg(argv[i]);
    if (r) rc = r;
  }

  if (!rc) printf("regression checks: all passed\n");
  return rc;
}
