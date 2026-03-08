library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.common_pack.all;

entity cmdProc is
  port (
    clk         : in  STD_LOGIC;
    reset       : in  STD_LOGIC;
    rxnow       : in  STD_LOGIC;
    rxData      : in  STD_LOGIC_VECTOR (7 downto 0);
    rxdone      : out STD_LOGIC;
    ovErr       : in  STD_LOGIC;
    framErr     : in  STD_LOGIC;
    txData      : out STD_LOGIC_VECTOR (7 downto 0);
    txnow       : out STD_LOGIC;
    txdone      : in  STD_LOGIC;
    start       : out STD_LOGIC;
    numWords_bcd: out BCD_ARRAY_TYPE(2 downto 0);
    dataReady   : in  STD_LOGIC;
    byte        : in  STD_LOGIC_VECTOR (7 downto 0);
    maxIndex    : in  BCD_ARRAY_TYPE(2 downto 0);
    dataResults : in  CHAR_ARRAY_TYPE(0 to RESULT_BYTE_NUM-1);
    seqDone     : in  STD_LOGIC
  );
end cmdProc;

architecture FSM of cmdProc is

    type state_type is (
        IDLE,
        ECHO,
        ECHO_WAIT,
        GET_DIGIT,
        START_DP,
        WAIT_DATA,
        TX_HI,
        TX_HI_WAIT,
        TX_LO,
        TX_LO_WAIT,
        TX_SPACE,
        TX_SPACE_WAIT,
        WAIT_READY_LOW
    );

    signal state, next_state : state_type := IDLE;

    -- Registered data
    signal echo_reg, next_echo_reg       : std_logic_vector(7 downto 0) := (others => '0');
    signal hundreds, next_hundreds       : unsigned(3 downto 0) := (others => '0');
    signal tens, next_tens               : unsigned(3 downto 0) := (others => '0');
    signal ones, next_ones               : unsigned(3 downto 0) := (others => '0');
    signal digit_count, next_digit_count : unsigned(1 downto 0) := (others => '0');
    signal cmd_valid, next_cmd_valid     : std_logic := '0';
    signal tx_byte, next_tx_byte         : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_phase, next_tx_phase       : unsigned(1 downto 0) := (others => '0');
    signal byte_idx, next_byte_idx       : unsigned(2 downto 0) := (others => '0');
    signal peak_idx, next_peak_idx       : unsigned(1 downto 0) := (others => '0');

    -- Latched results (captured on seqDone)
    signal reg_dataResults : CHAR_ARRAY_TYPE(0 to RESULT_BYTE_NUM-1) := (others => (others => '0'));
    signal reg_maxIndex    : BCD_ARRAY_TYPE(2 downto 0) := (others => (others => '0'));
    signal data_complete   : std_logic := '0';

    function to_hex(nibble : std_logic_vector(3 downto 0)) return std_logic_vector is
    begin
        case nibble is
            when "0000" => return x"30";
            when "0001" => return x"31";
            when "0010" => return x"32";
            when "0011" => return x"33";
            when "0100" => return x"34";
            when "0101" => return x"35";
            when "0110" => return x"36";
            when "0111" => return x"37";
            when "1000" => return x"38";
            when "1001" => return x"39";
            when "1010" => return x"41";
            when "1011" => return x"42";
            when "1100" => return x"43";
            when "1101" => return x"44";
            when "1110" => return x"45";
            when "1111" => return x"46";
            when others => return x"3F";
        end case;
    end function;

begin

    numWords_bcd(2) <= std_logic_vector(hundreds);
    numWords_bcd(1) <= std_logic_vector(tens);
    numWords_bcd(0) <= std_logic_vector(ones);

    --------------------------------------------------------------------------
    -- State register
    --------------------------------------------------------------------------
    state_reg: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state <= IDLE;
            else
                state <= next_state;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- Data registers
    --------------------------------------------------------------------------
    data_reg: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                echo_reg    <= (others => '0');
                hundreds    <= (others => '0');
                tens        <= (others => '0');
                ones        <= (others => '0');
                digit_count <= (others => '0');
                cmd_valid   <= '0';
                tx_byte     <= (others => '0');
                tx_phase    <= (others => '0');
                byte_idx    <= (others => '0');
                peak_idx    <= (others => '0');
            else
                echo_reg    <= next_echo_reg;
                hundreds    <= next_hundreds;
                tens        <= next_tens;
                ones        <= next_ones;
                digit_count <= next_digit_count;
                cmd_valid   <= next_cmd_valid;
                tx_byte     <= next_tx_byte;
                tx_phase    <= next_tx_phase;
                byte_idx    <= next_byte_idx;
                peak_idx    <= next_peak_idx;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- seqDone capture: latch dataResults and maxIndex
    --------------------------------------------------------------------------
    seq_done_capture: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                data_complete   <= '0';
                reg_dataResults <= (others => (others => '0'));
                reg_maxIndex    <= (others => (others => '0'));
            elsif state = START_DP then
                data_complete <= '0';
            elsif seqDone = '1' then
                reg_dataResults <= dataResults;
                reg_maxIndex    <= maxIndex;
                data_complete   <= '1';
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- Combinational logic: next state + outputs
    --------------------------------------------------------------------------
    comb_logic: process(state, rxnow, rxData, txdone, dataReady, byte,
                        data_complete, echo_reg, hundreds, tens, ones,
                        digit_count, cmd_valid, tx_byte, tx_phase,
                        byte_idx, peak_idx, reg_dataResults, reg_maxIndex)
    begin
        -- Defaults
        next_state       <= state;
        next_echo_reg    <= echo_reg;
        next_hundreds    <= hundreds;
        next_tens        <= tens;
        next_ones        <= ones;
        next_digit_count <= digit_count;
        next_cmd_valid   <= cmd_valid;
        next_tx_byte     <= tx_byte;
        next_tx_phase    <= tx_phase;
        next_byte_idx    <= byte_idx;
        next_peak_idx    <= peak_idx;

        rxdone <= '0';
        txnow  <= '0';
        txData <= (others => '0');
        start  <= '0';

        case state is

            ----------------------------------------------------------------
            -- IDLE: wait for UART character
            ----------------------------------------------------------------
            when IDLE =>
                if rxnow = '1' then
                    rxdone <= '1';
                    next_echo_reg <= rxData;
                    if rxData = x"41" or rxData = x"61" then  -- 'A' or 'a'
                        next_cmd_valid   <= '1';
                        next_digit_count <= (others => '0');
                    else
                        next_cmd_valid <= '0';
                    end if;
                    next_state <= ECHO;
                end if;

            ----------------------------------------------------------------
            -- ECHO: initiate TX of echo character
            ----------------------------------------------------------------
            when ECHO =>
                txData <= echo_reg;
                txnow  <= '1';
                next_state <= ECHO_WAIT;

            ----------------------------------------------------------------
            -- ECHO_WAIT: wait for TX done, then branch
            ----------------------------------------------------------------
            when ECHO_WAIT =>
                txData <= echo_reg;
                if txdone = '1' then
                    if cmd_valid = '0' then
                        next_state <= IDLE;
                    elsif digit_count = 3 then
                        next_state <= START_DP;
                    else
                        next_state <= GET_DIGIT;
                    end if;
                end if;

            ----------------------------------------------------------------
            -- GET_DIGIT: wait for BCD digit
            ----------------------------------------------------------------
            when GET_DIGIT =>
                if rxnow = '1' then
                    rxdone <= '1';
                    next_echo_reg <= rxData;
                    if rxData >= x"30" and rxData <= x"39" then
                        case digit_count is
                            when "00"   => next_hundreds <= unsigned(rxData(3 downto 0));
                            when "01"   => next_tens     <= unsigned(rxData(3 downto 0));
                            when "10"   => next_ones     <= unsigned(rxData(3 downto 0));
                            when others => null;
                        end case;
                        next_digit_count <= digit_count + 1;
                    else
                        next_cmd_valid <= '0';  -- invalid digit, abort
                    end if;
                    next_state <= ECHO;
                end if;

            ----------------------------------------------------------------
            -- START_DP: pulse start for one cycle
            ----------------------------------------------------------------
            when START_DP =>
                start <= '1';
                next_tx_phase <= "00";
                next_byte_idx <= (others => '0');
                next_peak_idx <= (others => '0');
                next_state    <= WAIT_DATA;

            ----------------------------------------------------------------
            -- WAIT_DATA: wait for streaming byte or sequence complete
            ----------------------------------------------------------------
            when WAIT_DATA =>
                if dataReady = '1' then
                    next_tx_byte <= byte;
                    next_state   <= TX_HI;
                elsif data_complete = '1' then
                    -- Streaming done, start printing results
                    next_tx_phase <= "01";
                    next_byte_idx <= (others => '0');
                    next_tx_byte  <= reg_dataResults(0);
                    next_state    <= TX_HI;
                end if;

            ----------------------------------------------------------------
            -- TX_HI: send high nibble
            ----------------------------------------------------------------
            when TX_HI =>
                txData <= to_hex(tx_byte(7 downto 4));
                txnow  <= '1';
                next_state <= TX_HI_WAIT;

            when TX_HI_WAIT =>
                txData <= to_hex(tx_byte(7 downto 4));
                if txdone = '1' then
                    next_state <= TX_LO;
                end if;

            ----------------------------------------------------------------
            -- TX_LO: send low nibble
            ----------------------------------------------------------------
            when TX_LO =>
                txData <= to_hex(tx_byte(3 downto 0));
                txnow  <= '1';
                next_state <= TX_LO_WAIT;

            when TX_LO_WAIT =>
                txData <= to_hex(tx_byte(3 downto 0));
                if txdone = '1' then
                    next_state <= TX_SPACE;
                end if;

            ----------------------------------------------------------------
            -- TX_SPACE: send space separator
            ----------------------------------------------------------------
            when TX_SPACE =>
                txData <= x"20";
                txnow  <= '1';
                next_state <= TX_SPACE_WAIT;

            ----------------------------------------------------------------
            -- TX_SPACE_WAIT: route to next action based on phase
            ----------------------------------------------------------------
            when TX_SPACE_WAIT =>
                txData <= x"20";
                if txdone = '1' then
                    case tx_phase is
                        when "00" =>  -- streaming phase
                            next_state <= WAIT_READY_LOW;

                        when "01" =>  -- results phase
                            if byte_idx < 6 then
                                next_byte_idx <= byte_idx + 1;
                                next_tx_byte  <= reg_dataResults(to_integer(byte_idx + 1));
                                next_state    <= TX_HI;
                            else
                                -- Switch to peak phase
                                next_tx_phase <= "10";
                                next_peak_idx <= (others => '0');
                                next_tx_byte  <= "0000" & reg_maxIndex(2);
                                next_state    <= TX_HI;
                            end if;

                        when "10" =>  -- peak phase
                            if peak_idx < 2 then
                                next_peak_idx <= peak_idx + 1;
                                case peak_idx is
                                    when "00"   => next_tx_byte <= "0000" & reg_maxIndex(1);
                                    when "01"   => next_tx_byte <= "0000" & reg_maxIndex(0);
                                    when others => null;
                                end case;
                                next_state <= TX_HI;
                            else
                                next_state <= IDLE;
                            end if;

                        when others =>
                            next_state <= IDLE;
                    end case;
                end if;

            ----------------------------------------------------------------
            -- WAIT_READY_LOW: wait for dataReady to deassert
            ----------------------------------------------------------------
            when WAIT_READY_LOW =>
                if dataReady = '0' then
                    next_state <= WAIT_DATA;
                end if;

            when others =>
                next_state <= IDLE;

        end case;
    end process;

end FSM;
