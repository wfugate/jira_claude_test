using System;

namespace Lending
{
    public class Loan
    {
        public string Isbn { get; set; }
        public string BookTitle { get; set; }
        public string MemberId { get; set; }
        public DateTime CheckedOutDate { get; set; }
        public DateTime DueDate { get; set; }
        public DateTime? ReturnedDate { get; set; }
        public int RenewalCount { get; set; }

        /// <summary>
        /// Why the most recent renewal attempt was refused, and when. Written by
        /// <see cref="LendingService.Renew"/> so that a member ringing up the next
        /// day can be told what happened, rather than the desk having to guess.
        ///
        /// Only the latest refusal is kept. A successful renewal does not clear it,
        /// so check <see cref="LastRenewalRefusedOn"/> against
        /// <see cref="RenewalCount"/> before reading it back to anyone: a refusal
        /// can predate a renewal that later went through.
        /// </summary>
        public RenewalBlock? LastRenewalRefusal { get; set; }
        public string LastRenewalRefusalExplanation { get; set; }
        public DateTime? LastRenewalRefusedOn { get; set; }
    }
}
