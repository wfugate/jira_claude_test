using System;
using System.Collections.Generic;
using System.Linq;

namespace Lending
{
    public class LendingService
    {
        private const int LoanPeriodDays = 21;
        private const int RenewalExtensionDays = 14;
        private const int MaxRenewals = 2;
        private const int MaxRenewalOverdueDays = 7;
        private const int MaxConcurrentLoans = 5;
        private const decimal DailyLateFee = 0.25m;
        private const decimal LateFeeCap = 10.00m;
        private const int GracePeriodDays = 3;
        private const decimal SuspensionThreshold = 15.00m;

        public Loan CheckOut(Book book, Member member, DateTime today,
                             IEnumerable<Loan> existingLoans,
                             bool staffOverride = false)
        {
            // Reference-only books are normally not lendable at all. Staff may
            // override that, but the loan is same-day only -- see DueDate below.
            if (book.IsReferenceOnly && !staffOverride)
                return null;

            if (member.IsSuspended)
                return null;

            if (member.OutstandingFees >= SuspensionThreshold)
                return null;

            int active = existingLoans.Count(l => l.MemberId == member.MemberId
                                                  && l.ReturnedDate == null);
            if (active >= MaxConcurrentLoans)
                return null;

            return new Loan
            {
                Isbn = book.Isbn,
                BookTitle = book.Title,
                MemberId = member.MemberId,
                CheckedOutDate = today,
                DueDate = book.IsReferenceOnly ? today : today.AddDays(LoanPeriodDays),
                RenewalCount = 0
            };
        }

        public bool Renew(Loan loan, Book book, DateTime today)
        {
            // A reference-only loan exists only under a same-day staff override,
            // so it must not be extendable past today.
            if (book.IsReferenceOnly)
                return false;

            int holdCount = book.HoldCount ?? 0;

            if (holdCount > 0)
                return false;

            if (loan.RenewalCount >= MaxRenewals)
                return false;

            int daysOverdue = (today - loan.DueDate).Days;
            if (daysOverdue > MaxRenewalOverdueDays)
                return false;

            loan.DueDate = loan.DueDate.AddDays(RenewalExtensionDays);
            loan.RenewalCount++;
            return true;
        }

        public decimal CalculateLateFee(Loan loan, DateTime today)
        {
            DateTime asOf = loan.ReturnedDate ?? today;
            int daysLate = (asOf - loan.DueDate).Days;
            if (daysLate <= GracePeriodDays)
                return 0m;

            decimal fee = daysLate * DailyLateFee;
            if (fee > LateFeeCap)
                fee = LateFeeCap;

            fee -= GracePeriodDays * DailyLateFee;
            return fee < 0m ? 0m : fee;
        }
    }
}
