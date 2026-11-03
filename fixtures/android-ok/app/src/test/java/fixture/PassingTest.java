package fixture;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

public class PassingTest {
    @Test
    public void addsNumbers() {
        assertEquals(4, 2 + 2);
    }
}
