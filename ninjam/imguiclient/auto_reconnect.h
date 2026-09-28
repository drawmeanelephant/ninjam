/*
    NINJAM GUI client - automatic reconnect policy.
*/

#ifndef NINJAM_AUTO_RECONNECT_H
#define NINJAM_AUTO_RECONNECT_H

#include <cmath>

class AutoReconnect
{
public:
  enum
  {
    STATUS_DISCONNECTED = -3,
    STATUS_INVALID_AUTH = -2,
    STATUS_CANT_CONNECT = -1,
    STATUS_CONNECTED = 0,
    STATUS_PRECONNECT = 1
  };

  AutoReconnect()
    : m_enabled(false), m_retry_eligible(false), m_retry_pending(false),
      m_retry_in_flight(false), m_attempt(0), m_last_status(STATUS_DISCONNECTED),
      m_retry_at(0.0)
  {
  }

  bool enabled() const { return m_enabled; }
  bool retry_pending() const { return m_retry_pending; }

  void set_enabled(bool enabled, int status, double now)
  {
    if (m_enabled == enabled) return;
    m_enabled = enabled;
    if (!m_enabled)
    {
      m_retry_pending = false;
      return;
    }

    if (m_retry_eligible && !m_retry_in_flight && is_retryable(status))
      schedule(now);
  }

  void manual_connect()
  {
    m_retry_eligible = false;
    m_retry_pending = false;
    m_retry_in_flight = false;
    m_attempt = 0;
    m_last_status = STATUS_PRECONNECT;
  }

  void manual_disconnect()
  {
    m_retry_eligible = false;
    m_retry_pending = false;
    m_retry_in_flight = false;
    m_attempt = 0;
    m_last_status = STATUS_DISCONNECTED;
  }

  void observe(int status, double now)
  {
    if (status == STATUS_CONNECTED)
    {
      m_retry_eligible = true;
      m_retry_pending = false;
      m_retry_in_flight = false;
      m_attempt = 0;
      m_last_status = status;
      return;
    }

    if (status == STATUS_PRECONNECT)
    {
      m_last_status = status;
      return;
    }

    if (status == STATUS_INVALID_AUTH)
    {
      m_retry_eligible = false;
      m_retry_pending = false;
      m_retry_in_flight = false;
      m_last_status = status;
      return;
    }

    const bool dropped = m_last_status == STATUS_CONNECTED && is_retryable(status);
    const bool retry_failed = m_retry_in_flight && is_retryable(status);
    if (retry_failed) m_retry_in_flight = false;
    if (m_enabled && m_retry_eligible && (dropped || retry_failed))
      schedule(now);
    m_last_status = status;
  }

  bool begin_retry(double now)
  {
    if (!m_retry_pending || now < m_retry_at) return false;
    m_retry_pending = false;
    m_retry_in_flight = true;
    m_last_status = STATUS_PRECONNECT;
    return true;
  }

  int seconds_until_retry(double now) const
  {
    if (!m_retry_pending) return -1;
    const double remaining = m_retry_at - now;
    return remaining > 0.0 ? (int)std::ceil(remaining) : 0;
  }

  void reset()
  {
    m_enabled = false;
    m_retry_eligible = false;
    m_retry_pending = false;
    m_retry_in_flight = false;
    m_attempt = 0;
    m_last_status = STATUS_DISCONNECTED;
    m_retry_at = 0.0;
  }

private:
  static bool is_retryable(int status)
  {
    return status == STATUS_DISCONNECTED || status == STATUS_CANT_CONNECT;
  }

  void schedule(double now)
  {
    if (!m_enabled || !m_retry_eligible || m_retry_pending) return;
    const double delay = m_attempt >= 6 ? 60.0 : (double)(1 << m_attempt);
    if (m_attempt < 6) m_attempt++;
    m_retry_at = now + delay;
    m_retry_pending = true;
  }

  bool m_enabled;
  bool m_retry_eligible;
  bool m_retry_pending;
  bool m_retry_in_flight;
  int m_attempt;
  int m_last_status;
  double m_retry_at;
};

#endif
