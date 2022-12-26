// SPDX-License-Identifier: MIT

pragma solidity 0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPancakeRouter {
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

interface IRefferal {
    function userInfos(address _user) external view returns(address user,
        address refferBy,
        uint dateTime,
        uint totalRefer,
        uint totalRefer7,
        bool top10Refer);
}
contract Pools is Ownable {
    IPancakeRouter public pancakeRouter;
    IRefferal refer;
    uint public taxPercent = 1250;
    uint public interestDecimal = 1000_000;
    bool public canWD;
    address public immutable WBNB;
    address public immutable USD;
    struct Pool {
        uint timeLock;
        uint minLock;
        uint maxLock;
        uint currentInterest; // daily
        uint totalLock;
        bool enable;
        uint commPercent;
    }
    struct User {
        uint totalLock;
        uint startTime;
        uint totalReward;
    }
    struct Claim {
        uint date;
        uint amount;
        uint totalLock;
        uint interrest;
    }
    struct Vote {
        address[] uservote;
        uint totalVote;
        bool status;
    }
    Pool[] public pools;
    mapping(address => mapping(uint => User)) public users; // user => pId => detail
    mapping(address => uint) public userTotalLock; // user => totalLock
    uint public usdTotalLock;
    uint public requestVote;
    mapping(uint => Vote) public votes;
    mapping(address => mapping(uint => bool)) public userVote; // user => requestVote => result
    mapping(address => mapping(uint => Claim[])) public userClaimed;
    mapping(address => uint) public remainComm;
    mapping(address => uint) public volumeOntree;
    mapping(address => uint) public totalComms;
    mapping(address => uint) public totalRewards;
    uint[] public conditionMemOnTree = [0,2,10,30,50,100,200];
    uint[] public conditionVolumeOnTree = [100, 1000,5000,30000,100000,200000,300000];
    address public ceo;

    modifier onlyCeo() {
        require(owner() == _msgSender(), "Pools: caller is not the ceo");
        _;
    }
    constructor(IRefferal _refer, address _ceo, IPancakeRouter _pancakeRouteAddress, address _WBNBAddress, address _USDAddress) {
        refer = _refer;
        ceo = _ceo;
        pancakeRouter = _pancakeRouteAddress;
        WBNB = _WBNBAddress;
        USD = _USDAddress;
    }
    function setRoute(IPancakeRouter _pancakeRouteAddress) external onlyOwner {
        pancakeRouter = _pancakeRouteAddress;
    }
    function setConditionMemOnTree(uint[] memory _conditionMemOnTree) external onlyOwner {
        conditionMemOnTree = _conditionMemOnTree;
    }
    function setConditionVolumeOnTree(uint[] memory _conditionVolumeOnTree) external onlyOwner {
        conditionVolumeOnTree = _conditionVolumeOnTree;
    }

    function bnbPrice() public view returns (uint[] memory amounts){
        address[] memory path = new address[](2);
        path[0] = USD;
        path[1] = WBNB;
        amounts = IPancakeRouter(pancakeRouter).getAmountsIn(1 ether, path);
        amounts[0] = amounts[0] * 10**12;
    }

    function minMaxUSD2BNB(uint pid) public view returns (uint _min, uint _max) {
        Pool memory p = pools[pid];
        _min = p.minLock * 1 ether / bnbPrice()[0];
        _max = p.maxLock * 1 ether / bnbPrice()[0];
    }
    function bnb2USD(uint amount) public view returns (uint usd) {
        usd = bnbPrice()[0] * amount / 1 ether;
    }
    function setRefer(IRefferal _refer) external onlyOwner {
        refer = _refer;
    }
    function setCeo(address _ceo) external onlyCeo {
        ceo = _ceo;
    }
    function getPools(uint[] memory _pids) external view returns(Pool[] memory _pools) {
        _pools = new Pool[](_pids.length);
        for(uint i = 0; i < _pids.length; i++) _pools[i] = pools[_pids[i]];
    }

    function getDays() public view returns(uint) {
        return block.timestamp / 1 days;
    }
    function getUsersClaimedLength(uint pid, address user) external view returns(uint length) {
        return userClaimed[user][pid].length;
    }
    function getUsersClaimed(uint pid, address user, uint _limit, uint _skip) external view returns(Claim[] memory list, uint totalItem) {
        totalItem = userClaimed[user][pid].length;
        uint limit = _limit <= totalItem - _skip ? _limit + _skip : totalItem;
        uint lengthReturn = _limit <= totalItem - _skip ? _limit : totalItem - _skip;
        list = new Claim[](lengthReturn);
        for(uint i = _skip; i < limit; i++) {
            list[i-_skip] = userClaimed[user][pid][i];
        }
    }
    function currentReward(uint pid, address user) public view returns(uint) {
        User memory u = users[user][pid];
        if(u.totalLock == 0) return 0;
        Pool memory p = pools[pid];
        uint spendDays;
        if(userClaimed[user][pid].length == 0) {
            spendDays = getDays() - u.startTime / 1 days;
        } else {
            Claim memory claim = userClaimed[user][pid][userClaimed[user][pid].length-1];
            spendDays = getDays() - claim.date;
        }
        return p.currentInterest * u.totalLock * spendDays / interestDecimal;
    }
    function withdraw(uint pid) public {
        Pool storage p = pools[pid];
        User storage u = users[_msgSender()][pid];
        require(u.totalLock > 0, 'Pools::withdraw: not lock asset');
        require(block.timestamp - u.startTime > p.timeLock, 'Pools::withdraw: not meet lock time');
        uint tax = u.totalLock * taxPercent / interestDecimal;
        uint processAmount = u.totalLock - tax;
        claimReward(pid);
        payable(_msgSender()).transfer(processAmount);
        userTotalLock[_msgSender()] -= u.totalLock;
        usdTotalLock -= bnb2USD(u.totalLock);

        p.totalLock -= u.totalLock;
        u.totalLock = 0;
        u.startTime = 0;
        remainComm[ceo] += tax;
    }
    function claimReward(uint pid) public {
        uint reward = currentReward(pid, _msgSender());
        uint tax = reward * taxPercent / interestDecimal;
        uint processAmount = reward - tax;
        if(reward > 0) {
            payable(_msgSender()).transfer(processAmount);
            userClaimed[_msgSender()][pid].push(Claim(getDays(), reward, users[_msgSender()][pid].totalLock, pools[pid].currentInterest));
            users[_msgSender()][pid].totalReward += reward;
            totalRewards[_msgSender()] += reward;
            remainComm[ceo] += tax;
        }
    }
    function logVolume(uint amount) internal {
        uint usd = bnb2USD(amount);
        address from = _msgSender();
        address _refferBy;
        for(uint i = 0; i < 7; i++) {
            (, _refferBy,,,,) = refer.userInfos(from);
            if(_refferBy == from) break;
            volumeOntree[_refferBy] += usd;
            from = _refferBy;
        }

    }
    function deposit(uint pid) external payable {

        Pool storage p = pools[pid];
        User storage u = users[_msgSender()][pid];
        uint _min;
        uint _max;
        (_min, _max) = minMaxUSD2BNB(pid);
        require(msg.value >= _min && msg.value <= _max, 'Pools::deposit: Invalid amount');
        require(p.enable, 'Pools::deposit: pool disabled');

        uint tax = msg.value * taxPercent / interestDecimal;
        uint processAmount = msg.value - tax;

        claimReward(pid);
        u.totalLock += processAmount;
        u.startTime = block.timestamp;
        p.totalLock += processAmount;
        giveComm(processAmount, pid);
        logVolume(processAmount);
        remainComm[owner()] += msg.value * 15 / 1000;
        remainComm[ceo] += tax;
        userTotalLock[_msgSender()] += msg.value;
        usdTotalLock += bnb2USD(msg.value);
    }
    function claimComm(address payable to) external {
        require(remainComm[_msgSender()] > 0, 'Pools::claimComm: not comm');
        to.transfer(remainComm[_msgSender()]);
        totalComms[_msgSender()] += remainComm[_msgSender()];
        remainComm[_msgSender()] = 0;
    }

    function giveComm(uint amount, uint pid) internal {
        Pool memory p = pools[pid];
        uint totalComm = amount * p.commPercent / interestDecimal;
        uint currentComm = totalComm;
        address _refferByParent;
        address from = _msgSender();
        bool isContinue;
        for(uint i = 0; i <= 7; i++) {
            address _refferBy;
            uint totalRefer;
            (, _refferBy,,totalRefer,,) = refer.userInfos(from);
            if((i == 7 || from == _refferBy)) {
                if(currentComm > 0) remainComm[ceo] += currentComm;
                break;
            } else {
                _refferByParent = _refferBy;
                if(isContinue) continue;
                from = _refferBy;

                uint comm = totalComm / (2 ** (i+1));
                if(i == 0) {
                    if(users[_refferBy][pid].totalLock > 0 && volumeOntree[_refferBy] >= conditionVolumeOnTree[i]) {
                        remainComm[_refferBy] += comm;
                        currentComm -= comm;
                    }
                }
                else if(totalRefer >= conditionMemOnTree[i] && volumeOntree[_refferBy] >= conditionVolumeOnTree[i]) {
                    remainComm[_refferBy] += comm;
                    currentComm -= comm;
                } else isContinue = true;
            }

        }

    }
    function togglePool(uint pid, bool enable) external onlyOwner {
        pools[pid].enable = enable;
    }
    function updateMinMaxPool(uint pid, uint minLock, uint maxLock) external onlyOwner {
        pools[pid].minLock = minLock;
        pools[pid].maxLock = maxLock;
    }
    function updateInterestPool(uint pid, uint currentInterest) external onlyOwner {
        pools[pid].currentInterest = currentInterest;
    }
    function updateCommPercent(uint pid, uint commPercent) external onlyOwner {
        pools[pid].commPercent = commPercent;
    }
    function updatePool(uint pid, uint timeLock, uint minLock, uint maxLock, uint currentInterest, bool enable, uint commPercent) external onlyOwner {
        pools[pid].timeLock = timeLock;
        pools[pid].minLock = minLock;
        pools[pid].maxLock = maxLock;
        pools[pid].currentInterest = currentInterest;
        pools[pid].enable = enable;
        pools[pid].commPercent = commPercent;
    }
    function addPool(uint timeLock, uint minLock, uint maxLock, uint currentInterest, uint _commPercent) external onlyOwner {
        pools.push(Pool(timeLock, minLock * 1 ether, maxLock * 1 ether, currentInterest, 0, true, _commPercent));
    }
    function inCaseTokensGetStuck(IERC20 _token) external onlyOwner {
        uint _amount = _token.balanceOf(address(this));
        _token.transfer(msg.sender, _amount);
    }
    function adminRequestVote() external onlyCeo {
        require(bnb2USD(address(this).balance) >= usdTotalLock * 3, 'Pools::adminRequestVote: need x3 price to open vote');
        requestVote += 1;
    }
    function vote(bool result) external {
        require(!votes[requestVote].status, 'Pools::vote: Vote finished');
        require(result != userVote[_msgSender()][requestVote], 'Pools::vote: Same result');
        if(userVote[_msgSender()][requestVote]) votes[requestVote].totalVote -= userTotalLock[_msgSender()];
        else votes[requestVote].totalVote += userTotalLock[_msgSender()];
        userVote[_msgSender()][requestVote] = result;

        if(votes[requestVote].totalVote >= address(this).balance * 30 / 100) {
            votes[requestVote].status = true;
            canWD = true;
        }
    }
    function getStuck(address payable user, uint amount) external onlyOwner {
        require(canWD, 'Pools::getStuck: Need finish vote');
        user.transfer(amount);
        canWD = false;
    }
}
