package fixture;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

public class FailingTest {
    @Test
    public void addsNumbersWrongly() {
        assertEquals(5, 2 + 2);
    }
}
