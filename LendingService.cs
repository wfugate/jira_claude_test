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
                             IEnumerable<Loan> existingLoans)
        {
            if (book.IsReferenceOnly)
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
                DueDate = today.AddDays(LoanPeriodDays),
                RenewalCount = 0
            };
        }

        /// <summary>
        /// Answers up front whether <paramref name="loan"/> could be renewed
        /// right now, so the desk can tell the member before they try.
        ///
        /// Read-only: it never touches the loan. <see cref="Renew"/> decides by
        /// calling this, so the two cannot drift apart and the reason recorded on
        /// a refused loan is word for word what the desk was told up front.
        /// </summary>
        public RenewalEligibility CheckRenewalEligibility(Loan loan, Book book, DateTime today)
        {
            int holdCount = book.HoldCount ?? 0;

            if (holdCount > 0)
                return RenewalEligibility.Blocked(
                    RenewalBlock.HoldsPending,
                    "Someone is waiting on this title, so it cannot be renewed. "
                    + "We cannot say when it will come free again, because that "
                    + "depends on when the member ahead brings it back. This copy "
                    + "needs to come back to the desk by "
                    + loan.DueDate.ToShortDateString() + ".");

            if (loan.RenewalCount >= MaxRenewals)
                return RenewalEligibility.Blocked(
                    RenewalBlock.RenewalLimitReached,
                    "This loan has already been renewed " + loan.RenewalCount
                    + " times, and " + MaxRenewals + " is the limit. The count does "
                    + "not reset, so there is no later date at which this loan can "
                    + "be renewed again. It is due back "
                    + loan.DueDate.ToShortDateString() + ".");

            int daysOverdue = (today - loan.DueDate).Days;
            if (daysOverdue > MaxRenewalOverdueDays)
                return RenewalEligibility.Blocked(
                    RenewalBlock.TooFarOverdue,
                    "This loan is " + daysOverdue + " days overdue, and renewals "
                    + "stop after " + MaxRenewalOverdueDays + " days overdue. Waiting "
                    + "will not bring it back under the cutoff, so this loan cannot "
                    + "be renewed again at any point. It needs to come back to the "
                    + "desk now.");

            return RenewalEligibility.Eligible();
        }

        /// <summary>
        /// Renews <paramref name="loan"/> if it can be, and records why not if it
        /// cannot. The refusal is written to the loan itself, because otherwise the
        /// reason exists only in the moment: a member who rings the next day to ask
        /// why they were turned away leaves the desk with nothing to look at.
        /// </summary>
        public bool Renew(Loan loan, Book book, DateTime today)
        {
            RenewalEligibility eligibility = CheckRenewalEligibility(loan, book, today);

            if (!eligibility.IsEligible)
            {
                loan.LastRenewalRefusal = eligibility.Reason;
                loan.LastRenewalRefusalExplanation = eligibility.Explanation;
                loan.LastRenewalRefusedOn = today;
                return false;
            }

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

        public int[] NoticeThresholdDays = new[] { 7, 14 };

        public OverdueNotice BuildOverdueNotice(Loan loan, DateTime today, DeskQueue queue)
        {
            if (loan.IsReferenceOnly) return null;
            if (loan.HasFeeWaiver) return null;

            int daysLate = (today - loan.DueDate).Days;

            int reached = 0;
            foreach (int t in NoticeThresholdDays)
                if (daysLate >= t && t > reached) reached = t;

            if (reached == 0) return null;
            if (queue.AlreadyQueued(loan, reached)) return null;

            return new OverdueNotice
            {
                Loan = loan,
                ThresholdDays = reached,
                QueuedOn = today,
                FeeAccruedSoFar = CalculateLateFee(loan, today)
            };
        }

        public void ClearSuspensionIfPaid(Member member)
        {
            if (member.OutstandingFees <= 0m)
                member.IsSuspended = false;
        }
    }
}
