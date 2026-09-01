using System;
using System.Collections.Generic;
using System.Linq;

namespace Lending
{
    public class DeskQueue
    {
        private readonly List<OverdueNotice> _queued = new List<OverdueNotice>();

        public void Add(OverdueNotice notice)
        {
            if (AlreadyQueued(notice.Loan, notice.ThresholdDays)) return;
            _queued.Add(notice);
        }

        public bool AlreadyQueued(Loan loan, int thresholdDays)
        {
            return _queued.Any(n => n.Loan == loan && n.ThresholdDays == thresholdDays);
        }

        public IEnumerable<OverdueNotice> ForBorrower(string borrowerName)
        {
            return _queued.Where(n => n.Loan.BorrowerName == borrowerName);
        }

        public IEnumerable<OverdueNotice> All()
        {
            return _queued.OrderBy(n => n.QueuedOn);
        }
    }
}
