namespace Lending
{
    /// <summary>
    /// Why a loan cannot be renewed. One value per check in
    /// <see cref="LendingService.CheckRenewalEligibility"/>, in the order they
    /// are applied: the first check that blocks is the reason reported.
    /// </summary>
    public enum RenewalBlock
    {
        None = 0,
        HoldsPending,
        RenewalLimitReached,
        TooFarOverdue
    }

    /// <summary>
    /// The answer to "can this be renewed?", asked before anyone tries.
    /// </summary>
    public class RenewalEligibility
    {
        public bool IsEligible { get; set; }
        public RenewalBlock Reason { get; set; }

        /// <summary>
        /// Plain wording desk staff can read back to the member. It answers both
        /// halves of what gets asked at the desk: why not, and when instead.
        /// Where no honest "when" exists it says so rather than guessing --
        /// a hold clears when the member ahead returns the book, and we have no
        /// way to know that, so a date there would only be wrong out loud.
        /// </summary>
        public string Explanation { get; set; }

        public static RenewalEligibility Eligible()
        {
            return new RenewalEligibility
            {
                IsEligible = true,
                Reason = RenewalBlock.None,
                Explanation = "This loan can be renewed."
            };
        }

        public static RenewalEligibility Blocked(RenewalBlock reason, string explanation)
        {
            return new RenewalEligibility
            {
                IsEligible = false,
                Reason = reason,
                Explanation = explanation
            };
        }
    }
}
