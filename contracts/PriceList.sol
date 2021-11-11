pragma solidity =0.5.16;

contract PriceList {
    //每一个位置对应一个价格数组(方向 -> 价格 -> 下一个价格) 需要对价格排序 （索引表示价格在map中的顺序）
    mapping(uint => mapping(uint => uint)) private limitOrderPriceListMap;
    //每一个位置对应一个价格(方向 -> 长度) （用于遍历所有价格时的边界）
    mapping(uint => uint) private limitOrderPriceArrayLength;

    // 链接长度
    function priceLength(
        uint direction)
    internal
    view
    returns (uint priceArrayLength) {
        priceArrayLength = limitOrderPriceArrayLength[direction];
    }

    // 查找插入位置-上一个位置 + 当前位置
    function priceLocation(
        uint direction,
        uint price)
    internal
    view
    returns (uint preIndex, uint next) {
        preIndex = 0;
        next = limitOrderPriceListMap[direction][0];
        if (direction == 1) { //由大到小排列
            while(next > price) {
                preIndex = next;
                next = limitOrderPriceListMap[direction][next];
                if (next == 0){
                    break;
                }
            }
        }
        else if (direction == 2) {//由小到大排列
            while(next < price) {
                preIndex = next;
                next = limitOrderPriceListMap[direction][next];
                if (next == 0){
                    break;
                }
            }
        }
    }

    function addPrice(
        uint direction,
        uint price)
    internal {//外部调用保证没有重复
        uint priceArrayLength = limitOrderPriceArrayLength[direction];
        if (priceArrayLength == 0) {//第一个元素
            limitOrderPriceListMap[direction][0] = price;
            limitOrderPriceListMap[direction][price] = 0;
        }
        else {
            (uint preIndex, uint nextIndex) = priceLocation(direction, price);
            limitOrderPriceListMap[direction][preIndex] = price;
            limitOrderPriceListMap[direction][price] = nextIndex;
        }

        limitOrderPriceArrayLength[direction]++;
    }

    function delPrice(
        uint direction,
        uint price)
    internal {//外部调用保证元素存在
        (uint preIndex, uint nextIndex) = priceLocation(direction, price);
        require(price == nextIndex, 'Invalid price');
        limitOrderPriceListMap[direction][preIndex] = limitOrderPriceListMap[direction][nextIndex];
        delete limitOrderPriceListMap[direction][nextIndex];
        limitOrderPriceArrayLength[direction]--;
    }

    function nextPrice(
        uint direction,
        uint cur) //从0开始获取下一个价格，next为0时结束
    internal
    view
    returns (uint next) {
        next = limitOrderPriceListMap[direction][cur];
    }
}