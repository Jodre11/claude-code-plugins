using System;
using System.Text;

namespace JbInspectSmoke
{
    public class BadCode
    {
        public int LengthOfNothing()
        {
            string value = null;
            return value.Length;
        }

        private void UnusedHelper()
        {
            Console.WriteLine("never called");
        }
    }
}
