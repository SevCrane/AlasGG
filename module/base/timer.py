from time import time, sleep
from datetime import datetime, timedelta
from functools import wraps


# def timeout(_timeout):
#     threadstop = thread._thread__stop
#     from threading import thread
#
#     class TimeOutException:
#         pass
#
#     def decorator(function):
#         def decorator2(*args, **kwargs):
#             class TimeLimited(thread):
#                 def __init__(self, _error=None):
#                     thread.__init__(self)
#                     self._error = _error
#
#                 def run(self):
#                     try:
#                         self.result = function(*args, **kwargs)
#                     except Exception as e:
#                         self._error = str(e)
#
#                 def _stop(self):
#                     if self.isalive():
#                         threadstop(self)
#
#                 @property
#                 def error(self):
#                     return self._error
#
#             t = TimeLimited()
#             t.start()
#             t.join(timeout)
#             if isinstance(t.error, TimeOutException):
#                 t._stop()
#                 raise TimeOutException('timeout for %s' % (repr(function)))
#             if t.isalive():
#                 t._stop()
#                 raise TimeOutException('timeout for %s' % (repr(function)))
#             if t._error is None:
#                 return t.result
#
#         return decorator2
#
#     return decorator
def timeout(func, timeout_sec=30.0, *args, **kwargs):
    """Won't kill that task until it finishes"""
    from threading import Thread
    from module.logger import logger

    def function_timeout(func):
        t0 = time.time()
        success = True
        p = Thread(target=func, args=args, kwargs=kwargs)
        p.start()
        p.join(timeout_sec)
        if p.is_alive():
            success = False
        t1 = time.time()
        if t1 - t0 < 10:
            success = False
        _success = 'Done' if success else 'Failed'
        logger.hr(f'{func.__name__}: {_success} in {str(round(t1 - t0, 1))}s', 1)
        if not success:
            return True
        return False
    return function_timeout(func)


def timer(function):
    """
    Decorator to time a function, for debug only
    """

    @wraps(function)
    def function_timer(*args, **kwargs):
        start = time()
        result = function(*args, **kwargs)
        cost = time() - start
        print(f'{function.__name__}: {cost:.10f} s')
        return result

    return function_timer


def future_time(string):
    """
    Args:
        string (str): Such as 14:59.

    Returns:
        datetime.datetime: Time with given hour, minute in the future.
    """
    hour, minute = [int(x) for x in string.split(':')]
    future = datetime.now().replace(hour=hour, minute=minute, second=0, microsecond=0)
    future = future + timedelta(days=1) if future < datetime.now() else future
    return future


def past_time(string):
    """
    Args:
        string (str): Such as 14:59.

    Returns:
        datetime.datetime: Time with given hour, minute in the past.
    """
    hour, minute = [int(x) for x in string.split(':')]
    past = datetime.now().replace(hour=hour, minute=minute, second=0, microsecond=0)
    past = past - timedelta(days=1) if past > datetime.now() else past
    return past


def future_time_range(string):
    """
    Args:
        string (str): Such as 23:30-06:30.

    Returns:
        tuple(datetime.datetime): (time start, time end).
    """
    start, end = [future_time(s) for s in string.split('-')]
    if start > end:
        start = start - timedelta(days=1)
    return start, end


def time_range_active(time_range):
    """
    Args:
        time_range(tuple(datetime.datetime)): (time start, time end).

    Returns:
        bool:
    """
    return time_range[0] < datetime.now() < time_range[1]


class Timer:
    def __init__(self, limit, count=0):
        """
        Dual timer for time count and access count.
        Access count can provide robustness on slow devices where screen shot time cost > timer.limit

        Args:
            limit (int | float): Timer limit
            count (int): Timer access count. Default to 0.
        """
        self.limit = limit
        self.count = count
        self._start = 0.
        self._access = 0

    @classmethod
    def from_seconds(cls, limit, speed=0.5):
        """
        Create timer from given seconds

        Args:
            limit (int | float):
            speed (int | float): Approximate screen shot time cost
                if time cost > 0.5s, device is considered slow
        """
        count = int(limit / speed)
        return cls(limit, count=count)

    def start(self):
        """
        Start current timer.
        If timer not started, reached() always return True. So we can have fast first try on:

        interval = Timer(2)
        while 1:
            if interval.reached():
                pass
        """
        if self._start <= 0:
            self._start = time()
            self._access = 0

        return self

    def started(self):
        """
        Returns:
            bool:
        """
        return self._start > 0

    def current_time(self):
        """
        Returns:
            float:
        """
        if self._start > 0:
            diff = time() - self._start
            if diff < 0:
                diff = 0.
            return diff
        else:
            return 0.

    def current_count(self):
        """
        Returns:
            int:
        """
        return self._access

    def add_count(self):
        self._access += 1
        return self

    def reached(self):
        """
        Returns:
            bool:
        """
        # each reached() call is consider as an access
        self._access += 1
        if self._start > 0:
            return self._access > self.count and time() - self._start > self.limit
        else:
            # not started, return True for fast first try
            return True

    def reset(self):
        """
        Reset the timer as if it just started
        """
        self._start = time()
        self._access = 0
        return self

    def clear(self):
        """
        Reset the timer as if it never started
        """
        self._start = 0.
        self._access = self.count
        return self

    def reached_and_reset(self):
        """
        Returns:
            bool:
        """
        if self.reached():
            self.reset()
            return True
        else:
            return False

    def wait(self):
        """
        Wait until timer reached.
        """
        diff = self._start + self.limit - time()
        if diff > 0:
            sleep(diff)

    def show(self):
        from module.logger import logger
        logger.info(str(self))

    def __str__(self):
        # Timer(limit=2.351/3, count=4/6)
        return f'Timer(limit={round(self.current_time(), 3)}/{self.limit}, count={self._access}/{self.count})'

    __repr__ = __str__
