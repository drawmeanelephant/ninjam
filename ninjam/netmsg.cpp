/*
    NINJAM - netmsg.cpp
    Copyright (C) 2005-2007 Cockos Incorporated

    NINJAM is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    NINJAM is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with NINJAM; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
*/

/*

  This file provides the implementations of the Net_Messsage class, and
  Net_Connection class (handles sending and receiving Net_Messages to
  a JNetLib JNL_Connection).

*/


#ifdef _WIN32
#include <windows.h>
#else
#include <stdlib.h>
#include <memory.h>
#endif

#include "netmsg.h"
#include "netcond.h"

int Net_Message::parseBytesNeeded()
{
  return get_size()-m_parsepos;
}

int Net_Message::parseAddBytes(void *data, int len)
{
  char *p=(char*)get_data();
  if (!p) return 0;
  if (len > parseBytesNeeded()) len = parseBytesNeeded();
  memcpy(p+m_parsepos,data,len);
  m_parsepos+=len;
  return len;
}

int Net_Message::parseMessageHeader(void *data, int len) // returns bytes used, if any (or 0 if more data needed) or -1 if invalid
{
  unsigned char *dp=(unsigned char *)data;
  if (len < 5) return 0;

  int type=*dp++;

  int size = *dp++;
  size |= ((int)*dp++)<<8;
  size |= ((int)*dp++)<<16;
  size |= ((int)*dp++)<<24;
  len -= 5;
  if (type == MESSAGE_INVALID || size < 0 || size > NET_MESSAGE_MAX_SIZE) return -1;

  m_type=type;
  set_size(size);

  m_parsepos=0;

  return 5;
}

int Net_Message::makeMessageHeader(void *data) // makes message header, data should be at least 16 bytes to be safe
{
  if (!data) return 0;

  unsigned char *dp=(unsigned char *)data;
  *dp++ = (unsigned char) m_type;
  int size=get_size();
  *dp++=size&0xff; size>>=8;
  *dp++=size&0xff; size>>=8;
  *dp++=size&0xff; size>>=8;
  *dp++=size&0xff;

  return (dp-(unsigned char *)data);
}



Net_Message *Net_Connection::Run(int *wantsleep)
{
  if (!m_con || m_error) return 0;

  // release any audio messages whose injected delay has now elapsed, so
  // they join the normal send queue before it is drained below
  pumpDelayed();

  // receive-side injector: peek at anything whose hold has elapsed. It is
  // only handed up at the end of the call, after anything newer parsed off
  // the wire this pass -- an audio message is never a keepalive, so the
  // keepalive bookkeeping below is unaffected.
  Net_Message *held=peekRxDue();

  {
    int s=0,r=0;
    m_con->run(-1,-1,&s,&r);
    if (wantsleep && (s||r)) *wantsleep=0;
  }

  time_t now=time(NULL);

  if (m_sendq.Available() > 0) m_last_send=now;
  else if (now > m_last_send + m_keepalive)
  {
    Net_Message *keepalive= new Net_Message;
    keepalive->set_type(MESSAGE_KEEPALIVE);
    keepalive->set_size(0);
    Send(keepalive);
    m_last_send=now;
  }

  // handle sending
  while (m_con->send_bytes_available()>64 && m_sendq.Available()>0)
  {
    Net_Message **topofq = (Net_Message **)m_sendq.Get();

    if (!topofq) break;
    Net_Message *sendm=*topofq;
    if (sendm)
    {
      if (wantsleep) *wantsleep=0;
      if (m_msgsendpos<0) // send header
      {
        char buf[32];
        int hdrlen=sendm->makeMessageHeader(buf);
        m_con->send_bytes(buf,hdrlen);

        m_msgsendpos=0;
      }

      int sz=sendm->get_size()-m_msgsendpos;
      if (sz < 1) // end of message, discard and move to next
      {
        sendm->releaseRef();
        m_sendq.Advance(sizeof(Net_Message*));
        m_msgsendpos=-1;
      }
      else
      {
        int avail=m_con->send_bytes_available();
        if (sz > avail) sz=avail;
        if (sz>0)
        {
          m_con->send_bytes((char*)sendm->get_data()+m_msgsendpos,sz);
          m_msgsendpos+=sz;
        }
      }
    }
    else
    {
      m_sendq.Advance(sizeof(Net_Message*));
      m_msgsendpos=-1;
    }
    {
      int s=0,r=0;
      m_con->run(-1,-1,&s,&r);
      if (wantsleep && (s||r)) *wantsleep=0;
    }
  }

  m_sendq.Compact();

  Net_Message *retv=0;

  // handle receive now
  if (!m_recvmsg)
  {
    m_recvmsg=new Net_Message;
    m_recvstate=0;
  }

  // Only take new bytes off the wire when nothing is still being held: TCP
  // itself provides the FIFO, so the hold must not work on bytes that would
  // let a later message slip past an earlier one still parked in m_rxdelayq.
  const bool wire_gate=m_rxdelayq.empty();
  bool parsed_any=false;

  while (!retv && wire_gate && m_con->recv_bytes_available()>0)
  {
    char buf[8192];
    int bufl=m_con->peek_bytes(buf,sizeof(buf));
    int a=0;

    if (!m_recvstate)
    {
      a=m_recvmsg->parseMessageHeader(buf,bufl);
      if (a<0)
      {
        m_error=-1;
        break;
      }
      if (a==0) break;
      m_recvstate=1;
    }
    int b2=m_recvmsg->parseAddBytes(buf+a,bufl-a);

    m_con->recv_bytes(buf,b2+a); // dump our bytes that we used

    if (m_recvmsg->parseBytesNeeded()<1)
    {
      parsed_any=true;

      // Receive-side adverse conditions: when the thread running this
      // connection has an inbound delay configured, audio messages are parked
      // (in completion order) instead of being handed up, exactly as the
      // send-side injector parks outbound ones in Send(). Only audio messages
      // are held; everything else passes through untouched, so auth and
      // config traffic is never delayed.
      const double rxd=NJCond::rx_delay_ms();
      if (rxd > 0.0 && NJCond::is_audio_message(m_recvmsg->get_type()))
      {
        enqueueRxDelayed(rxd, m_recvmsg);
        m_recvmsg=0;
        m_recvstate=0;
        m_last_recv=now; // data did arrive; keep the keepalive timer honest
        // m_recvmsg is NULL past this point and the hold now gates the wire,
        // so this receive pass is done; the next Run() re-enters cleanly.
        break;
      }
      else
      {
        retv=m_recvmsg;
        m_recvmsg=0;
        m_recvstate=0;
      }
    }
    if (wantsleep) *wantsleep=0;
  }

  {
    int s=0,r=0;
    m_con->run(-1,-1,&s,&r);
    if (wantsleep && (s||r)) *wantsleep=0;
  }


  if (retv)
  {
    m_last_recv=now;
  }
  else if (now > m_last_recv + m_keepalive*3)
  {
    m_error=-3;
  }

  // Deliver the held message only if nothing newer won this call. Two rules
  // fall out of the peek-then-decide-late shape:
  //  - parsed_any true  -> a message parsed off the wire this pass is newer
  //    than the held one, so it goes first and the held one stays parked for
  //    the next call. Delivering both would drop the held message; Run()
  //    returns at most one message.
  //  - parsed_any false -> the consumer had no other work. This is what keeps
  //    a one-message-per-call consumer (NJClient::Run) making progress at all:
  //    a message that is still inside its hold goes out early rather than
  //    stalling the protocol machine behind an empty wire.
  // Either way the hold never reorders anything: m_rxdelayq is strictly FIFO
  // (enqueueRxDelayed clamps due times non-decreasing), and the wire itself is
  // gated while anything is parked.
  if (!retv && held && !parsed_any)
  {
    m_rxdelayq.erase(m_rxdelayq.begin());
    retv=held;
  }

  return retv;
}

// m_delayq is kept sorted by (due, arrival seq), so a plain front-pop
// drains it in exactly the order Send() offered it. Send() also forces due
// times to be non-decreasing, so the sort is a formality: nothing can
// overtake anything.

// move every due entry from the front of the delay queue into m_sendq
void Net_Connection::pumpDelayed()
{
  if (m_delayq.empty()) return;

  double now=NJCond::now_ms();
  size_t n=0;
  while (n < m_delayq.size() && m_delayq[n].due <= now) n ++;
  if (!n) return;

  for (size_t x=0; x < n; x ++)
  {
    Net_Message *msg=m_delayq[x].msg;
    if (!msg) continue;

    if (m_sendq.GetSize() < NET_CON_MAX_MESSAGES*(int)sizeof(Net_Message *))
      m_sendq.Add(&msg,sizeof(Net_Message *));
    else
    {
      m_error=-2;
      msg->releaseRef();
    }
  }

  m_delayq.erase(m_delayq.begin(), m_delayq.begin()+n);
}

// insert into m_delayq, preserving (due, arrival) order
void Net_Connection::enqueueDelayed(double due_ms, Net_Message *msg)
{
  DelayedMsg d;
  d.due=due_ms;
  d.seq=m_delayseq++;
  d.msg=msg;

  size_t at=m_delayq.size();
  for (size_t x=0; x < m_delayq.size(); x ++)
  {
    if (m_delayq[x].due > d.due) { at=x; break; }
  }
  m_delayq.insert(m_delayq.begin()+at, d);
}

// park a completed inbound audio message for due_ms more milliseconds.
// The mirror of the send-side hold in Send(): the due time is clamped to be
// non-decreasing in completion order, so the release order is wire order and
// the hold can never reorder the stream -- the same property TCP gives the
// send side.
void Net_Connection::enqueueRxDelayed(double due_ms, Net_Message *msg)
{
  double due=NJCond::now_ms() + due_ms;
  if (due < m_lastrxdue) due=m_lastrxdue;
  m_lastrxdue=due;

  DelayedMsg d;
  d.due=due;
  d.seq=m_rxdelayseq++;
  d.msg=msg;

  size_t at=m_rxdelayq.size();
  for (size_t x=0; x < m_rxdelayq.size(); x ++)
  {
    if (m_rxdelayq[x].due > d.due) { at=x; break; }
  }
  m_rxdelayq.insert(m_rxdelayq.begin()+at, d);
}

// If the oldest held inbound audio message's due time has elapsed, hand it
// back WITHOUT removing it from the queue: the caller decides at the end of
// Run() whether it can actually be delivered this call (nothing newer was
// parsed) and pops it then. Deciding late keeps the queue the single source
// of order -- a peeked message that loses to a newer one simply stays parked.
Net_Message *Net_Connection::peekRxDue()
{
  if (m_rxdelayq.empty()) return 0;
  if (m_rxdelayq[0].due > NJCond::now_ms()) return 0;
  return m_rxdelayq[0].msg;
}

int Net_Connection::Send(Net_Message *msg)
{
  if (msg)
  {
    // adverse-conditions injector: drop or hold back audio messages.
    // Non-audio traffic is never touched.
    double delay_ms=0.0;
    if (!NJCond::admit(msg->get_type(), msg->get_size(), &delay_ms))
    {
      return 0; // dropped on the floor; the sender never learns
    }
    if (delay_ms > 0.0)
    {
      // Force the due time to be non-decreasing in Send() order. The
      // underlying transport is a single ordered TCP stream, so the network
      // can vary a message's latency but can never deliver a later message
      // first. Letting each message draw its own random delay would reorder
      // the audio messages of one interval, which is not a condition any
      // real network imposes on TCP -- it just scrambles the interval and
      // looks like codec failure. Clamping instead models what TCP actually
      // does: a slow message holds up everything queued behind it.
      double due=NJCond::now_ms() + delay_ms;
      if (due < m_lastdue) due=m_lastdue;
      m_lastdue=due;

      msg->addRef();
      enqueueDelayed(due, msg);
      return 0;
    }

    msg->addRef();
    if (m_sendq.GetSize() < NET_CON_MAX_MESSAGES*(int)sizeof(Net_Message *))
      m_sendq.Add(&msg,sizeof(Net_Message *));
    else
    {
      m_error=-2;
      msg->releaseRef(); // todo: debug message to log overrun error
      return -1;
    }

#if 0
    if (m_con)
    {
      m_con->run();

      while (m_con->send_bytes_available()>64 && m_sendq.Available()>0)
      {
        Net_Message **topofq = (Net_Message **)m_sendq.Get();

        if (!topofq) break;
        Net_Message *sendm=*topofq;
        if (sendm)
        {
          if (m_msgsendpos<0) // send header
          {
            char buf[32];
            int hdrlen=sendm->makeMessageHeader(buf);
            m_con->send_bytes(buf,hdrlen);

            m_msgsendpos=0;
          }

          int sz=sendm->get_size()-m_msgsendpos;
          if (sz < 1) // end of message, discard and move to next
          {
            sendm->releaseRef();
            m_sendq.Advance(sizeof(Net_Message*));
            m_msgsendpos=-1;
          }
          else
          {
            int avail=m_con->send_bytes_available();
            if (sz > avail) sz=avail;
            if (sz>0)
            {
              m_con->send_bytes((char*)sendm->get_data()+m_msgsendpos,sz);
              m_msgsendpos+=sz;
            }
          }
        }
        else
        {
          m_sendq.Advance(sizeof(Net_Message*));
          m_msgsendpos=-1;
        }
        m_con->run();
      }

      m_sendq.Compact();
    }
  #endif

  }
  return 0;
}

int Net_Connection::GetStatus()
{
  if (m_error) return m_error;
  return !m_con || m_con->get_state()<JNL_Connection::STATE_RESOLVING || m_con->get_state()>=JNL_Connection::STATE_CLOSING; // 1 if disconnected somehow
}

Net_Connection::~Net_Connection()
{
  // release anything still sitting in the adverse-conditions delay queues
  for (size_t x=0; x < m_delayq.size(); x ++)
    if (m_delayq[x].msg) m_delayq[x].msg->releaseRef();
  m_delayq.clear();

  for (size_t x=0; x < m_rxdelayq.size(); x ++)
    if (m_rxdelayq[x].msg) m_rxdelayq[x].msg->releaseRef();
  m_rxdelayq.clear();

  Net_Message **p=(Net_Message **)m_sendq.Get();
  if (p)
  {
    int n=m_sendq.Available()/sizeof(Net_Message *);
    while (n-->0)
    {
      (*p)->releaseRef();
      p++;
    }
    m_sendq.Advance(m_sendq.Available());

  }

  delete m_con;
  delete m_recvmsg;

}


void Net_Connection::Kill(int quick)
{
  m_con->close();
}
