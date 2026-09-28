/*
    NINJAM - tests/test_core.cpp

    Unit tests for the NINJAM protocol message layer (mpb/netmsg), the WDL
    support classes and njmisc helpers. Run via CTest or directly.
*/

#include <stdio.h>
#include <string.h>
#include <math.h>

#include "ninjam/mpb.h"
#include "ninjam/njmisc.h"
#include "WDL/sha.h"
#include "WDL/wdlstring.h"

static int g_checks=0, g_failures=0;

#define CHECK(cond) do { \
    g_checks++; \
    if (!(cond)) { g_failures++; printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } \
  } while (0)

static void hexs(const unsigned char *data, int len, char *out)
{
  static const char *hexd="0123456789abcdef";
  for (int x = 0; x < len; x ++)
  {
    out[x*2]=hexd[(data[x]>>4)&0xf];
    out[x*2+1]=hexd[data[x]&0xf];
  }
  out[len*2]=0;
}

// ---------------------------------------------------------------------------
static void test_sha1()
{
  // FIPS 180-1 test vectors
  WDL_SHA1 sha;
  unsigned char digest[20];
  char buf[64];

  sha.add("abc",3);
  sha.result(digest);
  hexs(digest,20,buf);
  CHECK(!strcmp(buf,"a9993e364706816aba3e25717850c26c9cd0d89d"));

  sha.reset();
  sha.result(digest);
  hexs(digest,20,buf);
  CHECK(!strcmp(buf,"da39a3ee5e6b4b0d3255bfef95601890afd80709"));

  sha.reset();
  sha.add("abcdbcdecdefdefgefghfghighijhi" "jkijkljklmklmnlmnomnopnopq",56);
  sha.result(digest);
  hexs(digest,20,buf);
  CHECK(!strcmp(buf,"84983e441c3bd26ebaae4aa1f95129e5e54670f1"));

  // incremental add must match one-shot
  sha.reset();
  sha.add("ab",2);
  sha.add("c",1);
  sha.result(digest);
  hexs(digest,20,buf);
  CHECK(!strcmp(buf,"a9993e364706816aba3e25717850c26c9cd0d89d"));
}

// ---------------------------------------------------------------------------
static void test_wdl_string()
{
  WDL_String s;
  CHECK(!strcmp(s.Get(),""));

  s.Set("hello");
  CHECK(!strcmp(s.Get(),"hello"));

  s.Append(" world");
  CHECK(!strcmp(s.Get(),"hello world"));

  s.Insert("brave ",6);
  CHECK(!strcmp(s.Get(),"hello brave world"));

  s.DeleteSub(5,7);
  CHECK(!strcmp(s.Get(),"helloworld"));

  s.SetLen(5);
  CHECK(!strcmp(s.Get(),"hello"));

  WDL_String t("copy me");
  CHECK(!strcmp(t.Get(),"copy me"));

  WDL_String u("truncateme",7);
  CHECK(!strcmp(u.Get(),"truncat"));
}

// ---------------------------------------------------------------------------
static void test_netmsg_framing()
{
  Net_Message m;
  m.set_type(MESSAGE_CHAT_MESSAGE);
  m.set_size(32);
  memset(m.get_data(),0xab,32);

  char hdr[16];
  int hl=m.makeMessageHeader(hdr);
  CHECK(hl==5);

  Net_Message r;
  CHECK(r.parseMessageHeader(hdr,hl)==5);
  CHECK(r.get_type()==MESSAGE_CHAT_MESSAGE);
  CHECK(r.get_size()==32);
  CHECK(r.parseBytesNeeded()==32);
  CHECK(r.parseAddBytes(m.get_data(),16)==16);
  CHECK(r.parseBytesNeeded()==16);
  CHECK(r.parseAddBytes((char*)m.get_data()+16,100)==16);
  CHECK(r.parseBytesNeeded()==0);
  CHECK(!memcmp(r.get_data(),m.get_data(),32));

  // incomplete header needs more data
  Net_Message r2;
  CHECK(r2.parseMessageHeader(hdr,3)==0);

  // invalid type is rejected
  char bad[5]={ (char)MESSAGE_INVALID, 1,0,0,0 };
  Net_Message r3;
  CHECK(r3.parseMessageHeader(bad,5)==-1);

  // oversized payload is rejected
  char big[5]={ 1, 0x00, 0x40, 0x00, 0x00 }; // 16384+... > NET_MESSAGE_MAX_SIZE
  big[1]=0xff; big[2]=0xff; big[3]=0xff; big[4]=0x7f;
  Net_Message r4;
  CHECK(r4.parseMessageHeader(big,5)==-1);
}

// ---------------------------------------------------------------------------
static void test_mpb_config_change()
{
  mpb_server_config_change_notify a;
  a.beats_minute=123;
  a.beats_interval=16;

  Net_Message *msg=a.build();
  CHECK(msg && msg->get_type()==MESSAGE_SERVER_CONFIG_CHANGE_NOTIFY);

  mpb_server_config_change_notify b;
  CHECK(b.parse(msg)==0);
  CHECK(b.beats_minute==123);
  CHECK(b.beats_interval==16);
  delete msg;
}

// ---------------------------------------------------------------------------
static void test_mpb_auth_challenge()
{
  mpb_server_auth_challenge a;
  for (int x = 0; x < 8; x ++) a.challenge[x]=(unsigned char)(x*7+1);
  a.server_caps=0x0305;
  a.protocol_version=PROTO_VER_CUR;
  a.license_agreement="Accept these terms?";

  Net_Message *msg=a.build();
  CHECK(msg && msg->get_type()==MESSAGE_SERVER_AUTH_CHALLENGE);

  mpb_server_auth_challenge b;
  CHECK(b.parse(msg)==0);
  CHECK(!memcmp(b.challenge,a.challenge,8));
  CHECK((b.server_caps&~1)==0x0304); // build() forces low bit per license_agreement
  CHECK(b.server_caps&1);
  CHECK(b.protocol_version==PROTO_VER_CUR);
  CHECK(b.license_agreement && !strcmp(b.license_agreement,"Accept these terms?"));
  delete msg;

  // no license agreement -> low bit cleared
  mpb_server_auth_challenge c;
  c.server_caps=0x0301;
  c.protocol_version=PROTO_VER_CUR;
  Net_Message *msg2=c.build();
  mpb_server_auth_challenge d;
  CHECK(d.parse(msg2)==0);
  CHECK(!(d.server_caps&1));
  CHECK(!d.license_agreement);
  delete msg2;
}

// ---------------------------------------------------------------------------
static void test_mpb_auth_reply()
{
  mpb_server_auth_reply a;
  a.flag=1;
  a.errmsg="bob_irc_name";
  a.maxchan=8;

  Net_Message *msg=a.build();
  mpb_server_auth_reply b;
  CHECK(b.parse(msg)==0);
  CHECK(b.flag==1);
  CHECK(b.errmsg && !strcmp(b.errmsg,"bob_irc_name"));
  CHECK(b.maxchan==8);
  delete msg;

  // failure case: no errmsg
  mpb_server_auth_reply c;
  c.flag=0;
  Net_Message *msg2=c.build();
  mpb_server_auth_reply d;
  CHECK(d.parse(msg2)==0);
  CHECK(d.flag==0);
  CHECK(!d.errmsg);
  delete msg2;
}

// ---------------------------------------------------------------------------
static void test_mpb_auth_user()
{
  mpb_client_auth_user a;
  for (int x = 0; x < 20; x ++) a.passhash[x]=(unsigned char)(x^0x5a);
  a.client_caps=2;
  a.client_version=PROTO_VER_CUR;
  a.username="alice";

  Net_Message *msg=a.build();
  CHECK(msg && msg->get_type()==MESSAGE_CLIENT_AUTH_USER);

  mpb_client_auth_user b;
  CHECK(b.parse(msg)==0);
  CHECK(!memcmp(b.passhash,a.passhash,20));
  CHECK(b.client_caps==2);
  CHECK(b.client_version==PROTO_VER_CUR);
  CHECK(b.username && !strcmp(b.username,"alice"));
  delete msg;
}

// ---------------------------------------------------------------------------
static void test_mpb_chat()
{
  mpb_chat_message a;
  a.parms[0]="MSG";
  a.parms[1]="alice";
  a.parms[2]="hello there";
  // parms[3], parms[4] left NULL

  Net_Message *msg=a.build();
  CHECK(msg && msg->get_type()==MESSAGE_CHAT_MESSAGE);

  mpb_chat_message b;
  CHECK(b.parse(msg)==0);
  CHECK(b.parms[0] && !strcmp(b.parms[0],"MSG"));
  CHECK(b.parms[1] && !strcmp(b.parms[1],"alice"));
  CHECK(b.parms[2] && !strcmp(b.parms[2],"hello there"));
  CHECK(!b.parms[3] || !b.parms[3][0]);
  CHECK(!b.parms[4] || !b.parms[4][0]);
  delete msg;
}

// ---------------------------------------------------------------------------
static void test_mpb_userinfo()
{
  mpb_server_userinfo_change_notify a;
  a.build_add_rec(1,3,(short)-60,-128,2,"bob","guitar");
  a.build_add_rec(1,0,(short)0,127,0,"alice","vox");
  a.build_add_rec(0,1,(short)-30,0,1,"carol","keys");

  Net_Message *msg=a.build();
  CHECK(msg && msg->get_type()==MESSAGE_SERVER_USERINFO_CHANGE_NOTIFY);

  mpb_server_userinfo_change_notify b;
  CHECK(b.parse(msg)==0);

  int offs=0, recs=0;
  for (;;)
  {
    int isActive=0, channelid=-1, pan=999, flags=-1;
    short volume=0;
    const char *username=0, *chname=0;
    offs=b.parse_get_rec(offs,&isActive,&channelid,&volume,&pan,&flags,&username,&chname);
    if (offs <= 0) break;
    recs++;
    switch (recs)
    {
      case 1:
        CHECK(isActive==1);
        CHECK(channelid==3);
        CHECK(volume==-60);
        CHECK(pan==-128);
        CHECK(flags==2);
        CHECK(username && !strcmp(username,"bob"));
        CHECK(chname && !strcmp(chname,"guitar"));
        break;
      case 2:
        CHECK(channelid==0);
        CHECK(volume==0);
        CHECK(pan==127);
        CHECK(username && !strcmp(username,"alice"));
        CHECK(chname && !strcmp(chname,"vox"));
        break;
      case 3:
        CHECK(isActive==0);
        CHECK(channelid==1);
        CHECK(volume==-30);
        CHECK(pan==0);
        CHECK(flags==1);
        CHECK(username && !strcmp(username,"carol"));
        CHECK(chname && !strcmp(chname,"keys"));
        break;
    }
  }
  CHECK(recs==3);
  delete msg;
}

// ---------------------------------------------------------------------------
static void test_mpb_usermask()
{
  mpb_client_set_usermask a;
  a.build_add_rec("bob",0x101u);
  a.build_add_rec("alice",0xffffffffu);

  Net_Message *msg=a.build();
  CHECK(msg && msg->get_type()==MESSAGE_CLIENT_SET_USERMASK);

  mpb_client_set_usermask b;
  CHECK(b.parse(msg)==0);

  int offs=0, recs=0;
  for (;;)
  {
    const char *username=0;
    unsigned int chflags=0;
    offs=b.parse_get_rec(offs,&username,&chflags);
    if (offs <= 0) break;
    recs++;
    if (recs==1)
    {
      CHECK(username && !strcmp(username,"bob"));
      CHECK(chflags==0x101u);
    }
    else if (recs==2)
    {
      CHECK(username && !strcmp(username,"alice"));
      CHECK(chflags==0xffffffffu);
    }
  }
  CHECK(recs==2);
  delete msg;
}

// ---------------------------------------------------------------------------
static void test_mpb_channel_info()
{
  mpb_client_set_channel_info a;
  a.mpisize=4;
  a.build_add_rec("guitar",(short)-30,64,1);
  a.build_add_rec("vox",(short)0,-128,0);

  Net_Message *msg=a.build();
  CHECK(msg && msg->get_type()==MESSAGE_CLIENT_SET_CHANNEL_INFO);

  mpb_client_set_channel_info b;
  CHECK(b.parse(msg)==0);

  int offs=0, recs=0;
  for (;;)
  {
    const char *chname=0;
    short volume=1;
    int pan=999, flags=-1;
    offs=b.parse_get_rec(offs,&chname,&volume,&pan,&flags);
    if (offs <= 0) break;
    recs++;
    if (recs==1)
    {
      CHECK(chname && !strcmp(chname,"guitar"));
      CHECK(volume==-30);
      CHECK(pan==64);
      CHECK(flags==1);
    }
    else if (recs==2)
    {
      CHECK(chname && !strcmp(chname,"vox"));
      CHECK(volume==0);
      CHECK(pan==-128);
      CHECK(flags==0);
    }
    CHECK(b.mpisize==4);
  }
  CHECK(recs==2);
  delete msg;
}

// ---------------------------------------------------------------------------
static void test_mpb_interval_begin()
{
  mpb_client_upload_interval_begin a;
  for (int x = 0; x < 16; x ++) a.guid[x]=(unsigned char)(x+1);
  a.estsize=123456;
  a.fourcc=0x4f474753; // 'OGGS'
  a.chidx=7;

  Net_Message *msg=a.build();
  CHECK(msg && msg->get_type()==MESSAGE_CLIENT_UPLOAD_INTERVAL_BEGIN);

  mpb_client_upload_interval_begin b;
  CHECK(b.parse(msg)==0);
  CHECK(!memcmp(b.guid,a.guid,16));
  CHECK(b.estsize==123456);
  CHECK(b.fourcc==0x4f474753u);
  CHECK(b.chidx==7);
  delete msg;

  // server->client direction shares the format
  mpb_server_download_interval_begin s;
  memcpy(s.guid,a.guid,16);
  s.estsize=999;
  s.fourcc=0x4f474753;
  s.chidx=2;
  s.username="bob";
  Net_Message *msg2=s.build();
  mpb_server_download_interval_begin t;
  CHECK(t.parse(msg2)==0);
  CHECK(!memcmp(t.guid,s.guid,16));
  CHECK(t.estsize==999);
  CHECK(t.fourcc==0x4f474753u);
  CHECK(t.chidx==2);
  CHECK(t.username && !strcmp(t.username,"bob"));
  delete msg2;
}

// ---------------------------------------------------------------------------
static void test_mpb_interval_write()
{
  unsigned char audio[37];
  for (int x = 0; x < 37; x ++) audio[x]=(unsigned char)(x*3);

  mpb_client_upload_interval_write a;
  for (int x = 0; x < 16; x ++) a.guid[x]=(unsigned char)(0xf0-x);
  a.flags=1;
  a.audio_data=audio;
  a.audio_data_len=37;

  Net_Message *msg=a.build();
  CHECK(msg && msg->get_type()==MESSAGE_CLIENT_UPLOAD_INTERVAL_WRITE);

  mpb_client_upload_interval_write b;
  CHECK(b.parse(msg)==0);
  CHECK(!memcmp(b.guid,a.guid,16));
  CHECK(b.flags==1);
  CHECK(b.audio_data_len==37);
  CHECK(b.audio_data && !memcmp(b.audio_data,audio,37));
  delete msg;

  // empty audio (interval begin w/ zero length write)
  mpb_client_upload_interval_write c;
  c.flags=0;
  Net_Message *msg2=c.build();
  mpb_client_upload_interval_write d;
  CHECK(d.parse(msg2)==0);
  CHECK(d.audio_data_len==0);
  delete msg2;
}

// ---------------------------------------------------------------------------
static void test_njmisc()
{
  // dB conversions: VAL2DB is the inverse of DB2VAL
  CHECK(fabs(VAL2DB(1.0)) < 1e-9);
  CHECK(fabs(DB2VAL(0.0)-1.0) < 1e-9);
  for (double v = 0.125; v <= 2.0; v *= 2.0)
    CHECK(fabs(DB2VAL(VAL2DB(v))-v) < 1e-9);

  // slider mapping is monotonic
  double s1=DB2SLIDER(0.0), s2=DB2SLIDER(6.0);
  CHECK(s2 > s1);

  char buf[128];
  mkvolstr(buf,1.0);
  CHECK(buf[0] != 0);
  mkpanstr(buf,0.0);
  CHECK(buf[0] != 0);
  mkvolpanstr(buf,1.0,0.0);
  CHECK(buf[0] != 0);
}

// ---------------------------------------------------------------------------
int main()
{
  test_sha1();
  test_wdl_string();
  test_netmsg_framing();
  test_mpb_config_change();
  test_mpb_auth_challenge();
  test_mpb_auth_reply();
  test_mpb_auth_user();
  test_mpb_chat();
  test_mpb_userinfo();
  test_mpb_usermask();
  test_mpb_channel_info();
  test_mpb_interval_begin();
  test_mpb_interval_write();
  test_njmisc();

  printf("%d checks, %d failures\n",g_checks,g_failures);
  return g_failures ? 1 : 0;
}
