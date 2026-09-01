using System;

namespace Lending
{
    public class OverdueNotice
    {
        public Loan Loan { get; set; }
        public int ThresholdDays { get; set; }
        public DateTime QueuedOn { get; set; }
        public decimal FeeAccruedSoFar { get; set; }

        public string Describe()
        {
            return Loan.BookTitle + " is " + ThresholdDays + " days overdue for "
                 + Loan.BorrowerName + ". Fees so far: " + FeeAccruedSoFar.ToString("C");
        }
    }
}
